#!/bin/bash
if [[ -z $VIRTUAL_ENV ]]; then
    source ${AIRFLOW_INSTALL_DIR}/venv/bin/activate 
fi

trap ctrl_c INT

function ctrl_c() {
    return 1
}

waitfordb() {
    # TODO: Este trecho não funciona com banco SQLite. Comparar com bancos remotos
    local CONNECTION=$(airflow config get-value database sql_alchemy_conn)
    local DATABASE_READY=1

    # Check if db is available
    while [ $DATABASE_READY -ne 0 ]; do
        echo "Waiting for database..." 
        sleep 2
        python -c "from sqlalchemy import create_engine as ce; ce('${CONNECTION}').connect().execute('SELECT 1')"
        DATABASE_READY=$?
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

echo "Executing: $1"
PID="${AIRFLOW_RUN_DIR}/airflow-$1-$(hostname).pid"
  
case "$1" in
    dev|standalone)
        install_modules
        exec airflow standalone
        ;;

    initdb|init)
        install_modules
        waitfordb
        # TODO: Criar rotina para criação de primeiro superuser
        # FIXME: Container não entra em estado complete no swarm
        exec airflow db migrate
        ;;

    webserver|scheduler|triggerer)
        install_modules
        waitfordb
        airflow db check-migrations
        exec airflow "$@" --pid $PID
        ;;

    worker)
        install_modules
        waitfordb
        airflow db check-migrations
        exec airflow celery "$@" --pid $PID
        ;;

    flower)
        install_modules
        waitfordb
        airflow db check-migrations
        # FIXME: Flower não sai do estado starting (Não gera PID)
        exec airflow celery "$@" --url-prefix flower --port 5555 --pid $PID
        ;;

    version)
        exec airflow version
        ;;

    info)
        exec airflow info
        ;;

    *)
        exec "$@"
        ;;
esac
