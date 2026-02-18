ARG PYTHON_VERSION=3.12
ARG DEBIAN_VERSION=trixie

ARG AIRFLOW_VERSION=2.10.5
ARG AIRFLOW_INSTALL_DIR=/var/lib/airflow

ARG ORACLE_INSTANTCLIENT_DIR=/opt/oracle


FROM python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS build 

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
ARG ORACLE_INSTANTCLIENT_URL="https://download.oracle.com/otn_software/linux/instantclient/1928000/instantclient-basiclite-linux.x64-19.28.0.0.0dbru.zip"
ARG ORACLE_INSTANTCLIENT_SDK_URL="https://download.oracle.com/otn_software/linux/instantclient/1928000/instantclient-sdk-linux.x64-19.28.0.0.0dbru.zip"

WORKDIR /tmp

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libaio1t64 && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    # install oracle client
    wget -qO oracle.zip ${ORACLE_INSTANTCLIENT_URL} && \
    wget -qO oracle-sdk.zip ${ORACLE_INSTANTCLIENT_SDK_URL} && \
    mkdir -p ${ORACLE_INSTANTCLIENT_DIR} && \
    unzip -d ${ORACLE_INSTANTCLIENT_DIR} oracle.zip && \
    unzip -od ${ORACLE_INSTANTCLIENT_DIR} oracle-sdk.zip && \
    _CLIENT_DIR=$(find /opt/oracle/ -name instantclient* -type d -print -quit) && \
    # create symlink to normalize name
    ln -s $_CLIENT_DIR ${ORACLE_INSTANTCLIENT_DIR}/instantclient && \
    # Fix error on find libaio1 on oracle
    ln -s $(find /usr/lib/x86_64-linux-gnu -name libaio.so.1* -type f -print -quit) libaio.so.1 && \
    echo $_CLIENT_DIR > /etc/ld.so.conf.d/oracle.conf && \
    ldconfig

# Install GDAL dependencies, with Oracle and Parquet support
RUN wget -O apache-arrow.deb https://packages.apache.org/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb && \
    dpkg -i apache-arrow.deb && \
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
ARG OSGEO_GDAL_VERSION=3.12.2

RUN set -xe && \
    wget -qO- https://download.osgeo.org/gdal/${OSGEO_GDAL_VERSION}/gdal-${OSGEO_GDAL_VERSION}.tar.gz | tar -zxvf - && \
    GDAL_DIR=gdal-${OSGEO_GDAL_VERSION} && \
    mkdir -p $GDAL_DIR/build && \
    cd $GDAL_DIR/build && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/gdal \
        -DGDAL_BUILD_OPTIONAL_DRIVERS=ON \
        -DOGR_BUILD_OPTIONAL_DRIVERS=ON \
        -DOracle_ROOT=/opt/oracle/instantclient \
        -DBUILD_PYTHON_BINDINGS=OFF \
    .. && \
    cmake --build . --target install && \
    cd .. && \
    rm -rf build/ && \
    ldconfig

ENV GDAL_DATA=/usr/local/share/gdal \
    PATH=/usr/gdal/bin:$PATH
    

# Install airflow
ARG AIRFLOW_PLUGINS="celery,elasticsearch,oracle,opensearch,postgres,mongo,mssql,samba,ssh,crypto"

WORKDIR ${AIRFLOW_INSTALL_DIR}

ARG AIRFLOW_ENV_CONSTRAINT_FILE="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

COPY requirements.txt .

RUN python -m venv --system-site-packages --prompt airflow venv && \
    . venv/bin/activate && \
    python -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    # Airflow
    python -m pip install --no-cache-dir --constraint ${AIRFLOW_ENV_CONSTRAINT_FILE} \
        "apache-airflow[${AIRFLOW_PLUGINS}]==${AIRFLOW_VERSION}" && \
    # Other 
    python -m pip install --no-cache-dir -r requirements.txt --constraint ${AIRFLOW_ENV_CONSTRAINT_FILE} && \
    # PyGDAL, based on distribution
    python -m pip install --no-cache-dir --constraint ${AIRFLOW_ENV_CONSTRAINT_FILE} \
        "gdal[numpy]==$(gdal-config --version).*" && \
    deactivate


FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS release

ARG AIRFLOW_INSTALL_DIR
ARG ORACLE_INSTANTCLIENT_DIR
ARG AIRFLOW_USER=airflow
ARG AIRFLOW_UID="50000"
ARG AIRFLOW_RUN_DIR=/var/run/airflow

# Apache Arrow
COPY --from=build /tmp/apache-arrow.deb /tmp/apache-arrow.deb

RUN apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        cowsay \
        curl \ 
        freetds-bin \
        git \
        gnupg \
        libaio1t64 \
        libspatialite8t64 librasterlite2-1 libjson-c5 libxerces-c3.2t64  libopenexr-3-1-30 \
        libkmlbase1t64 libkmlconvenience1t64 libkmldom1t64 libkmlengine1t64 libsfcgal2 gnupg libmariadb3 libmuparser2v5 \
        openssh-client \
        postgresql-client \
        sqlite3 \
        vim \
        tini \
        unzip && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

RUN dpkg -i /tmp/apache-arrow.deb && \
    apt-get -y update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
        libarrow-compute2300 libarrow-dataset2300 libparquet2300 && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*    

ENV AIRFLOW_INSTALL_DIR=${AIRFLOW_INSTALL_DIR} \
    AIRFLOW_HOME=${AIRFLOW_INSTALL_DIR}/home \
    AIRFLOW_RUN_DIR=${AIRFLOW_RUN_DIR} \
    PATH=/usr/gdal/bin:$PATH

# GDAL
COPY --from=build /usr/gdal /usr/gdal

# Virtualenv
COPY --from=build ${AIRFLOW_INSTALL_DIR}/venv ${AIRFLOW_INSTALL_DIR}/venv

# Oracle client
COPY --from=build ${ORACLE_INSTANTCLIENT_DIR} ${ORACLE_INSTANTCLIENT_DIR}
COPY --from=build /etc/ld.so.conf.d/oracle.conf /etc/ld.so.conf.d/oracle.conf

# Entrypoint
COPY scripts/docker-entrypoint.sh scripts/docker-healthcheck.sh scripts/airflow-init.sh /

VOLUME ${AIRFLOW_HOME}

WORKDIR ${AIRFLOW_INSTALL_DIR}

RUN set -o pipefail && \
    echo "/usr/gdal/lib" > /etc/ld.so.conf.d/gdal.conf && \
    # Fix error on find libaio1 on oracle
    ln -s $(find /usr/lib/x86_64-linux-gnu -name libaio.so.1* -type f -print -quit) /usr/lib/x86_64-linux-gnu/libaio.so.1 && \
    ldconfig && \
    # Make entrypoint executable
    chmod +x \
        /docker-entrypoint.sh \
        /docker-healthcheck.sh \
        /airflow-init.sh && \
    # add init script on root's .bashrc and skel
    printf "\n# Airflow \nsource /airflow-init.sh\n" | tee -a ~/.bashrc >> /etc/skel/.bashrc && \
    # add user airflow (required)
    useradd -u ${AIRFLOW_UID} -d ${AIRFLOW_HOME} -m ${AIRFLOW_USER} && \
    # create run dir
    mkdir -p ${AIRFLOW_RUN_DIR} && \
    chown airflow:root ${AIRFLOW_RUN_DIR} && \
    chmod -R g=u ${AIRFLOW_RUN_DIR}

USER ${AIRFLOW_UID}

WORKDIR ${AIRFLOW_HOME}

ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

CMD [ "standalone" ]
