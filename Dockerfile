ARG PYTHON_VERSION=3.12
ARG DEBIAN_VERSION=trixie

ARG AIRFLOW_VERSION=2.11.2
ARG AIRFLOW_INSTALL_DIR=/var/lib/airflow

ARG ORACLE_INSTANTCLIENT_DIR=/opt/oracle


FROM python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PYTHON_VERSION

ARG AIRFLOW_VERSION
ARG AIRFLOW_INSTALL_DIR

# Install dependencies
RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        build-essential \
        cmake \
        ca-certificates \
        libpq-dev \
        lsb-release \
        gnupg \
        unzip \
        wget && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Oracle
ARG ORACLE_INSTANTCLIENT_DIR

# SHA256 from Oracle download pages (linux-x86-64 / linux-arm-aarch64)
# v19.32.0.0.0
ARG ORACLE_BASICLITE_SHA256_X64=16947fc0fa55b861903aad6f9d2ddee7b4fedaf789a175ee36b46b82ec64fcbd
ARG ORACLE_SDK_SHA256_X64=1698b3be6dde8b7e90501a62122cb9c160c712eb709deb7129d915a504b76158

ARG ORACLE_BASICLITE_SHA256_ARM64=2c7c657b1e77b95a969e70f9af816b5e88f40047249c820936aa87a126d8e4f4
ARG ORACLE_SDK_SHA256_ARM64=be3b37817943102cb051fad80f5dc821821cf1616ffd0983c2ded81621c760d3

WORKDIR /tmp

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libaio1t64 && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    # install oracle client
    ARCH=$(dpkg --print-architecture | sed 's/amd/x/g') && \
    case "$ARCH" in \
        x64) BASICLITE_SHA256=${ORACLE_BASICLITE_SHA256_X64}; SDK_SHA256=${ORACLE_SDK_SHA256_X64} ;; \
        arm64) BASICLITE_SHA256=${ORACLE_BASICLITE_SHA256_ARM64}; SDK_SHA256=${ORACLE_SDK_SHA256_ARM64} ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    wget -qO oracle.zip "https://download.oracle.com/otn_software/linux/instantclient/1932000/instantclient-basiclite-linux.$ARCH-19.32.0.0.0dbru.zip" && \
    wget -qO oracle-sdk.zip "https://download.oracle.com/otn_software/linux/instantclient/1932000/instantclient-sdk-linux.$ARCH-19.32.0.0.0dbru.zip" && \
    # check integrity
    echo "${BASICLITE_SHA256}  oracle.zip" | sha256sum -c - && \
    echo "${SDK_SHA256}  oracle-sdk.zip" | sha256sum -c - && \
    mkdir -p "${ORACLE_INSTANTCLIENT_DIR}" && \
    unzip -d "${ORACLE_INSTANTCLIENT_DIR}" oracle.zip && \
    unzip -od "${ORACLE_INSTANTCLIENT_DIR}" oracle-sdk.zip && \
    # Fix error on find libaio1 on oracle
    ARCH=$(uname -m) && \
    ln -s "$(find "/usr/lib/$ARCH-linux-gnu" -name 'libaio.so.1*' -type f -print -quit)" "/usr/lib/$ARCH-linux-gnu/libaio.so.1" && \
    CLIENT_DIR=$(find "${ORACLE_INSTANTCLIENT_DIR}" -name 'instantclient*' -type d -print -quit) && \
    echo "$CLIENT_DIR" > /etc/ld.so.conf.d/oracle.conf && \
    ldconfig

# Install GDAL dependencies, with Oracle and Parquet support
# Fingerprints (space separated) of the keys allowed to sign the Arrow apt repository,
# taken from https://downloads.apache.org/arrow/KEYS
ARG APACHE_ARROW_SIGNER_FINGERPRINTS=7BD1A9A50E4F701BCBFD90EF9E922B2D60E9FD1C

RUN test -n "${APACHE_ARROW_SIGNER_FINGERPRINTS}" && \
    # keyring with only the pinned keys
    wget -qO arrow-KEYS https://downloads.apache.org/arrow/KEYS && \
    GNUPGHOME=$(mktemp -d) && \
    export GNUPGHOME && \
    gpg --batch --quiet --import arrow-KEYS && \
    for FPR in ${APACHE_ARROW_SIGNER_FINGERPRINTS}; do gpg --batch --list-keys "$FPR" > /dev/null || exit 1; done && \
    gpg --batch --export ${APACHE_ARROW_SIGNER_FINGERPRINTS} > /usr/share/keyrings/apache-arrow.gpg && \
    rm -rf "$GNUPGHOME" arrow-KEYS && \
    # repository
    printf "Types: deb\nURIs: https://packages.apache.org/artifactory/arrow/%s/\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/apache-arrow.gpg\n" \
        "$(lsb_release --id --short | tr '[:upper:]' '[:lower:]')" "$(lsb_release --codename --short)" \
        > /etc/apt/sources.list.d/apache-arrow.sources && \
    apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \ 
        swig \
        libarrow-dev \
        libarrow-compute-dev \       
        libarrow-dataset-dev \
        libexpat1-dev \
        libsfcgal-dev \
        libgeos-dev \
        libgeotiff-dev \
        libjson-c-dev \
        libkml-dev \
        libmariadb-dev \
        libmuparser-dev \
        libparquet-dev \ 
        libproj-dev \
        libprotobuf-dev \
        librasterlite2-dev \
        libspatialite-dev \
        # internal
        # libpng-dev \
        # libqhull-dev \
        libxerces-c-dev \
        libxml2-dev && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Compile and install GDAL
ARG OSGEO_GDAL_VERSION=3.12.4

RUN GDAL_URL=https://download.osgeo.org/gdal/${OSGEO_GDAL_VERSION}/gdal-${OSGEO_GDAL_VERSION}.tar.gz && \
    wget -q "${GDAL_URL}" "${GDAL_URL}.md5" && \
    md5sum -c "gdal-${OSGEO_GDAL_VERSION}.tar.gz.md5" && \
    tar -zxf "gdal-${OSGEO_GDAL_VERSION}.tar.gz" && \
    rm "gdal-${OSGEO_GDAL_VERSION}.tar.gz" "gdal-${OSGEO_GDAL_VERSION}.tar.gz.md5" && \
    GDAL_DIR=gdal-${OSGEO_GDAL_VERSION} && \
    mkdir -p "$GDAL_DIR/build" && \
    cd "$GDAL_DIR/build" && \
    cmake \
        -DCMAKE_CXX_FLAGS="-Wno-psabi" \
        -DCMAKE_C_FLAGS="-Wno-psabi" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/gdal \
        -DGDAL_BUILD_OPTIONAL_DRIVERS=ON \
        -DOGR_BUILD_OPTIONAL_DRIVERS=ON \
        -DOracle_ROOT="$(find "${ORACLE_INSTANTCLIENT_DIR}" -name 'instantclient*' -type d -print -quit)" \
        -DBUILD_PYTHON_BINDINGS=OFF \
    .. && \
    cmake --build . --target install && \
    cd .. && \
    rm -rf build/ && \
    ldconfig

ENV GDAL_DATA=/usr/gdal/share/gdal \
    PATH=/usr/gdal/bin:$PATH

# Install airflow
ARG AIRFLOW_PLUGINS="celery,elasticsearch,oracle,opensearch,postgres,mongo,mssql,mariadb,samba,ssh,crypto"

WORKDIR ${AIRFLOW_INSTALL_DIR}

COPY requirements.txt .

# TODO - Bring this to single sh
RUN python -m venv --system-site-packages --prompt airflow venv && \
    . venv/bin/activate && \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    # Airflow
    AIRFLOW_ENV_CONSTRAINT_FILE="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-$(python --version 2>&1 | grep -oE '[0-9]+\.[0-9]+').txt" && \
    python -m pip install --no-cache-dir --constraint "${AIRFLOW_ENV_CONSTRAINT_FILE}" \
        "apache-airflow[${AIRFLOW_PLUGINS}]==${AIRFLOW_VERSION}" && \
    # Other
    python -m pip install --no-cache-dir -r requirements.txt --constraint "${AIRFLOW_ENV_CONSTRAINT_FILE}" && \
    # PyGDAL, based on distribution
    python -m pip install --no-cache-dir --constraint "${AIRFLOW_ENV_CONSTRAINT_FILE}" \
        "gdal[numpy]==$(gdal-config --version).*" && \
    deactivate


FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS release

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG AIRFLOW_USER=50000
ARG AIRFLOW_INSTALL_DIR
ARG ORACLE_INSTANTCLIENT_DIR
ARG AIRFLOW_RUN_DIR=/var/run/airflow

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        cowsay \
        curl \ 
        freetds-bin \
        git \
        gnupg \
        libaio1t64 \
        libspatialite8t64 librasterlite2-1 libjson-c5 libxerces-c3.2t64 libopenexr-3-1-30 libkmlbase1t64 \
        libkmlconvenience1t64 libkmldom1t64 libkmlengine1t64 libsfcgal2 libmariadb3 libmuparser2v5 \
        opentelemetry-cpp \
        libnss-wrapper \
        openssh-client \
        postgresql-client \
        sqlite3 \
        vim \
        tini \
        unzip && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Apache Arrow
COPY --from=build /usr/share/keyrings/apache-arrow.gpg /usr/share/keyrings/apache-arrow.gpg
COPY --from=build /etc/apt/sources.list.d/apache-arrow.sources /etc/apt/sources.list.d/apache-arrow.sources

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libarrow-compute2600 libarrow-dataset2600 libparquet2600 && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*    

# GDAL
COPY --from=build /usr/gdal /usr/gdal

# Virtualenv
COPY --from=build ${AIRFLOW_INSTALL_DIR}/venv ${AIRFLOW_INSTALL_DIR}/venv

# Oracle client
COPY --from=build ${ORACLE_INSTANTCLIENT_DIR} ${ORACLE_INSTANTCLIENT_DIR}
COPY --from=build /etc/ld.so.conf.d/oracle.conf /etc/ld.so.conf.d/oracle.conf

# Entrypoint
COPY scripts/docker-entrypoint.sh scripts/docker-healthcheck.sh scripts/airflow-init.sh /

# HOME: a UID without passwd entry gets HOME=/ by default
ENV HOME=${AIRFLOW_INSTALL_DIR}/home \
    PATH=/usr/gdal/bin:$PATH \
    GDAL_DATA=/usr/gdal/share/gdal \
    AIRFLOW_INSTALL_DIR=${AIRFLOW_INSTALL_DIR} \
    AIRFLOW_HOME=${AIRFLOW_INSTALL_DIR}/home \
    AIRFLOW_RUN_DIR=${AIRFLOW_RUN_DIR}

# Last Configs
WORKDIR ${AIRFLOW_INSTALL_DIR}

RUN echo "/usr/gdal/lib" > /etc/ld.so.conf.d/gdal.conf && \
    # Fix error on find libaio1 on oracle
    ln -s "$(find "/usr/lib/$(uname -m)-linux-gnu" -name 'libaio.so.1*' -type f -print -quit)" "/usr/lib/$(uname -m)-linux-gnu/libaio.so.1" && \
    ldconfig && \
    # Make entrypoint executable
    chmod +x \
        /docker-entrypoint.sh \
        /docker-healthcheck.sh \
        /airflow-init.sh && \
    # add init script for all users' interactive shells
    printf "\n# Airflow \nsource /airflow-init.sh\n" >> /etc/bash.bashrc && \
    # create writable dirs for any UID with GID 0 (OpenShift)
    mkdir -p ${AIRFLOW_HOME} ${AIRFLOW_RUN_DIR} && \
    chown -R ${AIRFLOW_USER}:0 ${AIRFLOW_HOME} ${AIRFLOW_RUN_DIR} && \
    chmod -R g=u ${AIRFLOW_HOME} ${AIRFLOW_RUN_DIR}

WORKDIR ${AIRFLOW_HOME}

# Restore the default shell, so images built FROM this one don't inherit bash + pipefail
SHELL ["/bin/sh", "-c"]

# nss_wrapper: resolves the arbitrary UID (OpenShift) for every process, including docker exec.
# /tmp/passwd.nss is generated by the entrypoint
ENV NSS_WRAPPER_PASSWD=/tmp/passwd.nss \
    NSS_WRAPPER_GROUP=/etc/group \
    LD_PRELOAD=libnss_wrapper.so

USER ${AIRFLOW_USER}

ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

CMD [ "standalone" ]
