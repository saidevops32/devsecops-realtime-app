# syntax=docker/dockerfile:1
FROM erlang:26 AS build
WORKDIR /src
COPY rebar.config ./
COPY apps ./apps
RUN rebar3 as prod release

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 libncurses6 libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --no-create-home appuser
WORKDIR /app
COPY --from=build --chown=appuser /src/_build/prod/rel/worker ./
USER appuser
CMD ["/app/bin/worker", "foreground"]
