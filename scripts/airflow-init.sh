#!/bin/bash
# Airflow VirtualEnv and executables
alias activate='source $AIRFLOW_INSTALL_DIR/venv/bin/activate'

# local path for venv
if [[ -d $HOME/.local/bin ]]; then
    export PATH=$HOME/.local/bin:$PATH
fi
    
echo "Welcome to Airflow! Type 'activate' on shell to initialize the VirtualEnv" | /usr/games/cowsay -f tux 
