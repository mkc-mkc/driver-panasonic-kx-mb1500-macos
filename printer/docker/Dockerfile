FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        cups \
        cups-filters \
        file \
        ghostscript \
        libcups2-dev \
        make \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
