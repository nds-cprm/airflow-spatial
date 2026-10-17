#!/bin/bash
set -e 

if [[ -z $VIRTUAL_ENV ]]; then
    source ${AIRFLOW_INSTALL_DIR}/venv/bin/activate 
fi

trap ctrl_c INT

function ctrl_c() {
    return 1
}

waitfordb() {
    # TODO: Este trecho não funciona com banco SQLite. Comparar com bancos remotos
    # Check if db is available (connection read by Airflow, never exposed on the command line)
    until python -c 'from sqlalchemy import text; from airflow import settings; settings.engine.connect().execute(text("SELECT 1"))'; do
        echo "Waiting for database..."
        sleep 2
    done

    # check if Airflow schema is ready
    AIRFLOW_READY=$(airflow db check | grep -i fail | wc -l)
    if [[ $AIRFLOW_READY -gt 0 ]]; then
        echo "Database is online but it's not ready"
    else 
        echo "Database is ready and OK" 
    fi
    
    return 0
}

install_modules() {
    echo "Installing modules..."

    if [[ -n "$AIRFLOW_EXTRA_REQUIREMENTS_FILE" ]]; then
        if [[ -r "$AIRFLOW_EXTRA_REQUIREMENTS_FILE" ]]; then
            python -m pip install --user --no-cache-dir -r "$AIRFLOW_EXTRA_REQUIREMENTS_FILE"
        else
            echo "WARNING: requirements file <$AIRFLOW_EXTRA_REQUIREMENTS_FILE> does not exist, skipping..."
        fi
    fi
}

# NSS Wrapper
# Se o UID atual não puder ser resolvido para um nome (caso típico do OpenShift)
USER_EXISTS=$(cut -d: -f3 /etc/passwd | grep -x "$(id -u)" | wc -l)

if [ $USER_EXISTS -eq 0 ]; then
    # Injeta dinamicamente o UID aleatório atual associado ao nome "airflow"
    # O GID sempre será 0 no OpenShift Restricted SCC
    export NSS_WRAPPER_PASSWD=/tmp/passwd.nss 
    export NSS_WRAPPER_GROUP=/etc/group 
    export LD_PRELOAD=libnss_wrapper.so

    # Clona o passwd original do sistema para o nosso arquivo temporário
    cat /etc/passwd > "$NSS_WRAPPER_PASSWD"

    echo "airflow:x:$(id -u):0:Airflow OpenShift User:${AIRFLOW_HOME}:/bin/bash" >> "$NSS_WRAPPER_PASSWD"
    echo "nss_wrapper ativado: Usuário virtual 'airflow' criado para o UID $(id -u)"
fi

PID="${AIRFLOW_RUN_DIR}/airflow-$1-$(hostname).pid"
  
case "$1" in
    dev|standalone)
        install_modules
        echo "Executing: airflow standalone"
        exec airflow standalone
        ;;

    initdb|init)
        install_modules
        waitfordb
        # TODO: Criar rotina para criação de primeiro superuser
        # FIXME: Container não entra em estado complete no swarm
        echo "Executing: airflow db migrate"
        exec airflow db migrate
        ;;

    webserver|scheduler|triggerer)
        install_modules
        waitfordb
        echo "Executing: airflow $1"
        airflow db check-migrations
        exec airflow "$@" --pid $PID
        ;;

    worker)
        install_modules
        waitfordb
        echo "Executing: airflow worker"
        airflow db check-migrations
        exec airflow celery "$@" --pid $PID
        ;;

    flower)
        install_modules
        waitfordb
        airflow db check-migrations
        echo "Executing: celery flower"
        # FIXME: Flower não sai do estado starting (Não gera PID)
        # TODO: https://airflow.apache.org/docs/apache-airflow/2.10.5/howto/run-behind-proxy.html
        exec airflow celery "$@" --url-prefix flower --port 5555 --pid $PID
        ;;

    version)
        echo "Executing: airflow $1"
        exec airflow version
        ;;

    info)
        echo "Executing: airflow $1"
        exec airflow info
        ;;

    *)
        CMD="$@"
        echo "Executing: $CMD"
        exec "$CMD"
        ;;
esac
