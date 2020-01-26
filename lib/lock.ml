type t = { lock : Mutex.t }

let create () = { lock = Mutex.create () }

let with_lock t f =
  Mutex.lock t.lock;
  try
    let result = f () in
    Mutex.unlock t.lock;
    result
  with e ->
    Mutex.unlock t.lock;
    raise e
