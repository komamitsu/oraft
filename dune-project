(lang dune 3.6)

(name oraft)

(version 0.3.0)

(generate_opam_files true)

(source
 (github komamitsu/oraft))

(authors "Mitsunori Komatsu")

(maintainers "komamitsu@gmail.com")

(license "Apache-2.0")

(documentation https://github.com/komamitsu/oraft)

(package
 (name oraft)
 (synopsis "Raft consensus algorithm implemented in OCaml")
 (description "Raft consensus algorithm implemented in OCaml")
 (depends
  (ocaml (>= 4.14.0))
  dune
  (core (>= v0.16.0))
  (core_unix (>= v0.16.0))
  (cohttp-lwt-unix (>= 5.0.0))
  (sqlite3 (>= 5.0.0))
  yojson
  lwt_ppx
  ppx_deriving
  (ppx_deriving_yojson (>= 3.6.0))
  (ounit :with-test)
  (fileutils :with-test)
 )
 (tags (Raft lwt)))

