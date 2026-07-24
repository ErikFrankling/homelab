FROM debian:bookworm

ARG HERMES_COMMIT=43bca6d107c86efc7e60a4a35ca8a55e1b4b4c1e

RUN apt-get update && apt-get install -y \
    git nodejs npm python3 python3-pip \
    ripgrep ffmpeg gcc python3-dev libffi-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/NousResearch/hermes-agent.git /opt/hermes \
    && git -C /opt/hermes checkout "$HERMES_COMMIT" \
    && git -C /opt/hermes submodule update --init --recursive

WORKDIR /opt/hermes
RUN pip install -e ".[all]" --break-system-packages
RUN pip install -e "./mini-swe-agent" --break-system-packages
RUN npm install
RUN npx playwright install --with-deps chromium

COPY entrypoint.sh /opt/hermes/entrypoint.sh
RUN chmod +x /opt/hermes/entrypoint.sh

ENV HERMES_HOME=/opt/data
VOLUME ["/opt/data"]

ENTRYPOINT ["/opt/hermes/entrypoint.sh"]
CMD ["sleep", "infinity"]
