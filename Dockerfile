FROM ghcr.io/ptero-eggs/games:arma3

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/* \
    && mv /entrypoint.sh /entrypoint-upstream.sh

COPY --chown=container:container entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh /entrypoint-upstream.sh

USER container
