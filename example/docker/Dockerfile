FROM ubuntu:18.04
RUN apt update
RUN apt install -y make patch curl ocaml-nox m4 unzip bubblewrap
RUN curl -L -o /usr/local/bin/opam https://github.com/ocaml/opam/releases/download/2.0.6/opam-2.0.6-x86_64-linux && chmod +x /usr/local/bin/opam
RUN opam init --bare --disable-sandboxing
RUN opam switch create 4.09.0 ocaml-base-compiler.4.09.0
RUN opam install -y dune cohttp-lwt-unix core ppx_deriving ppx_deriving_yojson yojson fileutils
RUN opam install -y oUnit
RUN apt install -y tzdata netbase
WORKDIR /workspace
CMD opam exec -- dune exec --root /oraft example/oraft_example.exe 8181 conf.json
