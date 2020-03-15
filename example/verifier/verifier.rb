require 'parallel'
require 'faraday'

class Verifier
  RETRY = 32

  def initialize(concurrency, key_size, count)
    @concurrency = concurrency
    @key_size = key_size
    @count = count
    @clients = 1.upto(5).map do |i|
      Faraday.new("http://localhost:818#{i}", request: {
        open_timeout: 0.4,
        timeout: 0.8
      })
    end
    @errors = @clients.inject({}) {|a, x|
      a[x] = { last_ts: nil, count: 0 }
      a
    }
    @table = {}
  end

  def wait(init_wait, retry_factor, max_wait, retry_count)
    # Add plus/minus 10% jitter
    sleep([init_wait * (retry_factor ** retry_count), max_wait].min * (1.1 - Random.rand(0.2)))
  end

  def send_command(command, client = nil)
    RETRY.times.each do |i|
      client ||= @clients[Random.rand(5)]
      error = @errors[client] 
      if error[:last_ts] && Time.now - 5 < error[:last_ts]
        if error[:count] > 8
          puts "This client may be stalled. Trying another one... client=#{client.url_prefix}, command='#{command}'"
          client = nil
          next
        end
      else
        error[:count] = 0
      end

      # puts "client=#{client.url_prefix}, command='#{command}'"

      begin
        response = client.post("/command", command)
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError
        client = nil
        error[:last_ts] = Time.now
        error[:count] += 1
        wait(0.1, 2, 1.5, i)
        next
      end

      case response.status
      when 0...200
        raise "Unexpected response: response=#{response}, command='#{command}'"
      when 200...300
        error[:last_ts] = nil
        error[:count] = 0
        # puts "Success! command='#{command}'"
        return response.body
      when 400
        raise "Bad Request: command='#{command}'"
      when 404
        raise "Not Found: command='#{command}'"
      when 409
        puts "Conflict: command='#{command}'"
        # Conflict
        return nil
      else # >= 500
        puts "Temporary error: command='#{command}'"
        wait(0.1, 2, 1.5, i)
        next
      end
    end

    raise "Retry over (HTTP response): command='#{command}'"
  end

  def key(i)
    "key-#{i % @key_size}"
  end

  def initialize_values
    @key_size.times.each do |i|
      k = key(i)
      send_command("SET #{k} 0")
      @table[k] = 0
    end
  end

  def update_values
    Parallel.each(0...@count, :in_threads => @concurrency) do |i|
      retry_count = 0
      loop do
        if retry_count >= RETRY
          raise "Retry over (CAS): i='#{i}'"
        end

        k = key(i)
        v = send_command("GET #{k}")
        diff = Random.rand(100000)
        next_v = Integer(v) + diff

        # puts "[#{i}] diff=#{diff}"

        if send_command("CAS #{k} #{v} #{next_v}") || Integer(send_command("GET #{k}")) == next_v
          @table[k] += diff
          break
        end

        wait(0.1, 2, 1.5, retry_count)
        retry_count += 1
      end
    end
  end

  def verify_values
    puts
    puts "================================================================================"
    puts "Result"
    puts "--------------------------------------------------------------------------------"
    failed = 0
    @key_size.times.each do |i|
      k = key(i)
      puts "Key: #{k}"
      expected = @table[k]
      @clients.each do |client|
        v = Integer(send_command("GET #{k}", client))
        if v == expected
          puts "Success: expected=#{expected}, actual=#{v}"
        else
          puts "Failed:  expected=#{expected}, actual=#{v}"
          failed += 1
        end
      end
      puts "--------------------------------------------------------------------------------"
    end

    puts
    if failed == 0
      puts "All good"
    else
      puts "Detected any failure: failed_count=#{failed}"
    end
    puts
  end

  def run
    initialize_values

    update_values

    verify_values
  end
end

if $0 == __FILE__
  Verifier.new(16, 8, 512).run
end

