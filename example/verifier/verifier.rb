require 'parallel'
require 'faraday'

class Verifier
  def initialize(concurrency, keys, count)
    @concurrency = concurrency
    @keys = keys
    @count = count
    @uris = 1.upto(5).map do |i|
      "http://localhost:818#{i}/command"
    end
  end

  def send_command(command)
    10.times.each do
      uri = @uris[Random.rand(5)]

      puts "uri=#{uri}, command='#{command}'"

      begin
        response = Faraday.post(uri, command)
      rescue Faraday::ConnectionFailed
        next
      end

      case response.status
      when 0...200
        raise "Unexpected response: response=#{response}, command='#{command}'"
      when 200...300
        puts "Success! command='#{command}'"
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
        sleep 0.1
        next
      end
    end

    raise "Retry over (HTTP response): command='#{command}'"
  end

  def key(i)
    "key-#{i % @keys}"
  end

  def value(x)
    "#{x}"
  end

  def run
    @keys.times.each do |i|
      send_command("SET #{key(i)} #{value(i * 1000)}")
    end

    Parallel.each(1..@count, :in_threads => @concurrency) do |i|
      retry_count = 0
      loop do
        if retry_count >= 10
          raise "Retry over (CAS): i='#{i}'"
        end

        k = key(i)
        v = send_command("GET #{k}")
        next_v = Integer(v) + 1
        if send_command("CAS #{k} #{v} #{next_v}")
          break
        end
        sleep 0.1
        retry_count += 1
      end
    end
  end
end

if $0 == __FILE__
  Verifier.new(4, 3, 10).run
end

