# Build Stage
FROM --platform=linux/amd64 ubuntu:20.04 as builder

## Add source code to the build stage.

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y gcc

ADD . /shine
WORKDIR /shine/src/bin

## TODO: ADD YOUR BUILD INSTRUCTIONS HERE.
RUN gcc *.c ../lib/*.c -I../lib -lm -o shine

#Package Stage
FROM --platform=linux/amd64 ubuntu:20.04

## TODO: Change <Path in Builder Stage>
COPY --from=builder /shine/src/bin/shine /
