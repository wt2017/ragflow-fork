# base stage
FROM ubuntu:22.04 AS base
USER root

ARG NEED_MIRROR=0
ARG LIGHTEN=0
ENV LIGHTEN=${LIGHTEN}

WORKDIR /ragflow

# Copy models downloaded via download_deps.py
RUN mkdir -p /ragflow/rag/res/deepdoc /root/.ragflow
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/huggingface.co,target=/huggingface.co \
    cp /huggingface.co/InfiniFlow/huqie/huqie.txt.trie /ragflow/rag/res/ && \
    tar --exclude='.*' -cf - \
        /huggingface.co/InfiniFlow/text_concat_xgb_v1.0 \
        /huggingface.co/InfiniFlow/deepdoc \
        | tar -xf - --strip-components=3 -C /ragflow/rag/res/deepdoc 
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/huggingface.co,target=/huggingface.co \
    if [ "$LIGHTEN" != "1" ]; then \
        (tar -cf - \
            /huggingface.co/BAAI/bge-large-zh-v1.5 \
            /huggingface.co/maidalun1020/bce-embedding-base_v1 \
            | tar -xf - --strip-components=2 -C /root/.ragflow) \
    fi

# https://github.com/chrismattmann/tika-python
# This is the only way to run python-tika without internet access. Without this set, the default is to check the tika version and pull latest every time from Apache.
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/,target=/deps \
    cp -r /deps/nltk_data /root/ && \
    cp /deps/tika-server-standard-3.0.0.jar /deps/tika-server-standard-3.0.0.jar.md5 /ragflow/ && \
    cp /deps/cl100k_base.tiktoken /ragflow/9b5ad71b2ce5302211f9c61530b329a4922fc6a4

ENV TIKA_SERVER_JAR="file:///ragflow/tika-server-standard-3.0.0.jar"
ENV DEBIAN_FRONTEND=noninteractive

# Setup apt
# Python package and implicit dependencies:
# opencv-python: libglib2.0-0 libglx-mesa0 libgl1
# aspose-slides: pkg-config libicu-dev libgdiplus         libssl1.1_1.1.1f-1ubuntu2_amd64.deb
# python-pptx:   default-jdk                              tika-server-standard-3.0.0.jar
# selenium:      libatk-bridge2.0-0                       chrome-linux64-121-0-6167-85
# Building C extensions: libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev
RUN --mount=type=cache,id=ragflow_apt,target=/var/cache/apt,sharing=locked \
    if [ "$NEED_MIRROR" == "1" ]; then \
        sed -i 's|http://ports.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list; \
        sed -i 's|http://archive.ubuntu.com|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list; \
    fi; \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    chmod 1777 /tmp && \
    apt update && \
    apt --no-install-recommends install -y ca-certificates && \
    apt update && \
    apt install -y libglib2.0-0 libglx-mesa0 libgl1 && \
    apt install -y pkg-config libicu-dev libgdiplus && \
    apt install -y default-jdk && \
    apt install -y libatk-bridge2.0-0 && \
    apt install -y libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev && \
    apt install -y libjemalloc-dev && \
    apt install -y python3-pip pipx nginx unzip curl wget git vim less && \
    apt install -y ghostscript

# Temporary use mirror for initial pip setup to handle timeout issues
RUN pip3 config set global.index-url https://mirrors.aliyun.com/pypi/simple && \
    pip3 config set global.trusted-host mirrors.aliyun.com && \
    pip3 config set global.timeout 3000 && \
    pip3 install --no-cache-dir 'pip==23.3.1' && \
    pip3 install --no-cache-dir setuptools wheel && \
    pip3 install --no-cache-dir "uv==0.7.12" && \
    if [ "$NEED_MIRROR" != "1" ]; then \
        pip3 config unset global.index-url && \
        pip3 config unset global.trusted-host; \
    else \
        mkdir -p /etc/uv && \
        echo "[[index]]" > /etc/uv/uv.toml && \
        echo 'url = "https://mirrors.aliyun.com/pypi/simple"' >> /etc/uv/uv.toml && \
        echo "default = true" >> /etc/uv/uv.toml; \
    fi

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV PATH=/root/.local/bin:$PATH

# nodejs 12.22 on Ubuntu 22.04 is too old
RUN --mount=type=cache,id=ragflow_apt,target=/var/cache/apt,sharing=locked \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt purge -y nodejs npm cargo && \
    apt autoremove -y && \
    apt update && \
    apt install -y nodejs

# A modern version of cargo is needed for the latest version of the Rust compiler.
RUN apt update && apt install -y curl build-essential \
    && if [ "$NEED_MIRROR" == "1" ]; then \
         # Use TUNA mirrors for rustup/rust dist files
         export RUSTUP_DIST_SERVER="https://mirrors.tuna.tsinghua.edu.cn/rustup"; \
         export RUSTUP_UPDATE_ROOT="https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup"; \
         echo "Using TUNA mirrors for Rustup."; \
       fi; \
    # Force curl to use HTTP/1.1
    curl --proto '=https' --tlsv1.2 --http1.1 -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal \
    && echo 'export PATH="/root/.cargo/bin:${PATH}"' >> /root/.bashrc

ENV PATH="/root/.cargo/bin:${PATH}"

RUN cargo --version && rustc --version

# Add msssql ODBC driver
# macOS ARM64 environment, install msodbcsql18.
# general x86_64 environment, install msodbcsql17.
RUN --mount=type=cache,id=ragflow_apt,target=/var/cache/apt,sharing=locked \
    curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt update && \
    arch="$(uname -m)"; \
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
        # ARM64 (macOS/Apple Silicon or Linux aarch64)
        ACCEPT_EULA=Y apt install -y unixodbc-dev msodbcsql18; \
    else \
        # x86_64 or others
        ACCEPT_EULA=Y apt install -y unixodbc-dev msodbcsql17; \
    fi || \
    { echo "Failed to install ODBC driver"; exit 1; }



# Add dependencies of selenium
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/chrome-linux64-121-0-6167-85,target=/chrome-linux64.zip \
    unzip /chrome-linux64.zip && \
    mv chrome-linux64 /opt/chrome && \
    ln -s /opt/chrome/chrome /usr/local/bin/
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/chromedriver-linux64-121-0-6167-85,target=/chromedriver-linux64.zip \
    unzip -j /chromedriver-linux64.zip chromedriver-linux64/chromedriver && \
    mv chromedriver /usr/local/bin/ && \
    rm -f /usr/bin/google-chrome

# https://forum.aspose.com/t/aspose-slides-for-net-no-usable-version-of-libssl-found-with-linux-server/271344/13
# aspose-slides on linux/arm64 is unavailable
RUN --mount=type=bind,from=localhost/infiniflow/ragflow_deps:v0.19.0,source=/,target=/deps \
    if [ "$(uname -m)" = "x86_64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    elif [ "$(uname -m)" = "aarch64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_arm64.deb; \
    fi


# builder stage
FROM base AS builder
USER root

WORKDIR /ragflow

# Copy all source files first to ensure package can be built
COPY . .

RUN mkdir -p /root/.uv && \
    echo "[index]" > /root/.uv/config.toml && \
    echo "url = 'https://mirrors.aliyun.com/pypi/simple'" >> /root/.uv/config.toml && \
    echo "default = true" >> /root/.uv/config.toml && \
    echo "[network]" >> /root/.uv/config.toml && \
    echo "timeout = 3600" >> /root/.uv/config.toml && \
    echo "retries = 10" >> /root/.uv/config.toml && \
    echo "connect-timeout = 180" >> /root/.uv/config.toml && \
    echo "http2 = false" >> /root/.uv/config.toml && \
    echo "chunk-size = '10MB'" >> /root/.uv/config.toml && \
    echo "max-concurrent-downloads = 4" >> /root/.uv/config.toml

# https://github.com/astral-sh/uv/issues/10462
# uv records index url into uv.lock but doesn't failover among multiple indexes
ENV VIRTUAL_ENV=/ragflow/.venv
RUN --mount=type=cache,id=ragflow_uv,target=/root/.cache/uv,sharing=locked \
    mkdir -p /root/.uv && \
    echo "[index]\nurl = 'https://mirrors.aliyun.com/pypi/simple'\ndefault = true\n\n[network]\ntimeout = 3600\nretries = 10\nconnect-timeout = 180\nhttp2 = false\nchunk-size = '10MB'\nmax-concurrent-downloads = 4" > /root/.uv/config.toml && \
    export UV_HTTP_TIMEOUT=3600 && \
    export UV_NETWORK_TIMEOUT=3600 && \
    export UV_INDEX_URL=https://mirrors.aliyun.com/pypi/simple && \
    export UV_TRUSTED_HOST=mirrors.aliyun.com && \
    export UV_NO_H2=1 && \
    export UV_SEQUENTIAL=1 && \
    uv venv ${VIRTUAL_ENV} --python 3.10 && \
    if [ "$NEED_MIRROR" = "1" ]; then \
        sed -i 's|pypi.org|mirrors.aliyun.com/pypi|g' uv.lock; \
    else \
        sed -i 's|mirrors.aliyun.com/pypi|pypi.org|g' uv.lock; \
    fi && \
    PATH="${VIRTUAL_ENV}/bin:$PATH" && \
    PATH="${VIRTUAL_ENV}/bin:$PATH" && \
    if [ "$LIGHTEN" = "1" ]; then \
        # Install CUDA packages first to avoid conflicts
        echo "Installing CUDA packages..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install \
            --upgrade \
            'nvidia-cublas-cu12>=12.4.5.8' \
            'nvidia-cudnn-cu12>=9.1.0.70' \
            'nvidia-cuda-runtime-cu12>=12.4.5.8' \
            'nvidia-cuda-nvrtc-cu12>=12.4.5.8' && \
        echo "Installing torch..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install --upgrade 'torch>=2.6.0' && \
        echo "Installing embedding packages..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install --upgrade bcembedding fastembed flagembedding transformers && \
        echo "Installing package in development mode..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install -e .; \
    else \
        # Install CUDA packages first to avoid conflicts
        echo "Installing CUDA packages..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install \
            --upgrade \
            'nvidia-cublas-cu12>=12.4.5.8' \
            'nvidia-cudnn-cu12>=9.1.0.70' \
            'nvidia-cuda-runtime-cu12>=12.4.5.8' \
            'nvidia-cuda-nvrtc-cu12>=12.4.5.8' && \
        echo "Installing torch..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install --upgrade 'torch>=2.6.0' && \
        echo "Installing embedding packages with GPU support..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install --upgrade bcembedding fastembed-gpu flagembedding transformers && \
        echo "Installing package in development mode..." && \
        UV_NO_H2=1 UV_SEQUENTIAL=1 uv pip install -e .; \
    fi

COPY web web
COPY docs docs
RUN --mount=type=cache,id=ragflow_npm,target=/root/.npm,sharing=locked \
    cd web && npm install && npm run build

COPY .git /ragflow/.git

RUN version_info=$(git describe --tags --match=v* --first-parent --always); \
    if [ "$LIGHTEN" = "1" ]; then \
        version_info="$version_info slim"; \
    else \
        version_info="$version_info full"; \
    fi; \
    echo "RAGFlow version: $version_info"; \
    echo "$version_info" > /ragflow/VERSION

# production stage
FROM base AS production
USER root

WORKDIR /ragflow

# Copy Python environment and packages
ENV VIRTUAL_ENV=/ragflow/.venv
COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

ENV PYTHONPATH=/ragflow/

# Copy all source files in a specific order to ensure dependencies are available
COPY pyproject.toml uv.lock README.md LICENSE ./
COPY web web
COPY api api
COPY conf conf
COPY deepdoc deepdoc
COPY rag rag
COPY agent agent
COPY graphrag graphrag
COPY agentic_reasoning agentic_reasoning
COPY mcp mcp
COPY plugin plugin

COPY docker/service_conf.yaml.template ./conf/service_conf.yaml.template
COPY docker/entrypoint.sh ./
RUN chmod +x ./entrypoint*.sh

# Copy compiled web pages
COPY --from=builder /ragflow/web/dist /ragflow/web/dist

COPY --from=builder /ragflow/VERSION /ragflow/VERSION
ENTRYPOINT ["./entrypoint.sh"]
