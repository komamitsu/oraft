# This Dockerfile should be used from the project root directory

FROM ubuntu:18.04 AS build-env
RUN apt update && apt install -y make patch curl ocaml-nox m4 unzip pkg-config bubblewrap
RUN curl -L -o /usr/local/bin/opam https://github.com/ocaml/opam/releases/download/2.0.6/opam-2.0.6-x86_64-linux && chmod +x /usr/local/bin/opam
RUN opam init --bare --disable-sandboxing
RUN opam switch create 4.09.0 ocaml-base-compiler.4.09.0
RUN opam install -y dune cohttp-lwt-unix core ppx_deriving ppx_deriving_yojson yojson fileutils oUnit
COPY . /build
WORKDIR /build
RUN opam exec -- dune build --profile=release

FROM ubuntu:18.04
RUN apt update && apt install -y tzdata netbase netcat tcpdump net-tools
COPY --from=build-env /build/_build/default/example/oraft_example.exe /
WORKDIR /workspace
CMD /oraft_example.exe 8181 conf.json
