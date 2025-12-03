FROM kong:3.9.1

USER root

RUN apt-get update && apt-get -y install curl make libssl-dev openssh-client gcc musl-dev
RUN luarocks install redis-lua

USER kong
