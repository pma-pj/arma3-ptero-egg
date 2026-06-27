# Syntax: docker/dockerfile:1
#
# Keep the upstream Arma 3 yoke intact and only wrap its entrypoint.
# The upstream entrypoint still performs all server and Workshop downloading.
FROM ghcr.io/ptero-eggs/games:arma3

USER root

# curl is already present in the base image. jq is used to parse Steam's JSON
# response safely rather than scraping HTML.
RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/* \
    && mv /entrypoint.sh /entrypoint-upstream.sh

COPY --chown=container:container entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh /entrypoint-upstream.sh

USER container

# The base image keeps its tini ENTRYPOINT and CMD ["/entrypoint.sh"].
# Our wrapper resolves the collection, then execs /entrypoint-upstream.sh.
