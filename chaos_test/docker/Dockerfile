# This Dockerfile should be used from the project root directory

FROM ubuntu:latest
RUN apt update && apt install -y tzdata netbase netcat tcpdump net-tools iproute2 libsqlite3-dev
COPY _build/default/example-kv/oraft_kv.exe /
WORKDIR /workspace
CMD /oraft_kv.exe 8181 conf.json
