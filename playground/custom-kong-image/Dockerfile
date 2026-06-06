FROM kong:3.9.2

USER root

# curl is handy for poking the Admin API from inside the container.
# No extra Lua rocks are needed: the plugin uses lua-resty-redis, which ships
# with Kong/OpenResty.
RUN apt-get update && apt-get -y install curl

USER kong
