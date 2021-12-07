# This Dockerfile should be used from the project root directory

FROM ubuntu:latest
RUN apt update && apt install -y tzdata netbase netcat tcpdump net-tools
COPY _build/default/example/oraft_example.exe /
WORKDIR /workspace
CMD /oraft_example.exe 8181 conf.json
