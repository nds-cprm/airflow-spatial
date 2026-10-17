# Construção da imagem Docker

Este documento descreve como o [Dockerfile](../Dockerfile) constrói a imagem do Airflow com suporte espacial (GDAL com drivers Oracle, Parquet/Arrow, SpatiaLite, etc.), quais parâmetros ele aceita e como manter as versões e verificações de integridade atualizadas.

## Visão geral

A imagem é construída em dois estágios:

| Estágio | Base | Função |
|---|---|---|
| `build` | `python:<versão>-<debian>` | Compila o GDAL, instala o Oracle Instant Client e cria o virtualenv do Airflow |
| `release` | `python:<versão>-slim-<debian>` | Imagem final: recebe só os artefatos do `build` e as bibliotecas de runtime |

Ferramentas de compilação (`build-essential`, `cmake`, headers `-dev`) ficam somente no estágio `build` e não vão para a imagem final.

## Build rápido

```bash
docker build -t airflow-spatial:local .
```

Com parâmetros explícitos (os mesmos usados no CI):

```bash
docker build \
  --build-arg PYTHON_VERSION=3.12 \
  --build-arg DEBIAN_VERSION=trixie \
  --build-arg AIRFLOW_VERSION=2.11.2 \
  -t airflow-spatial:2.11.2-py3.12 .
```

Para gerar imagem ARM64 (o Dockerfile suporta `amd64` e `arm64`):

```bash
docker buildx build --platform linux/arm64 -t airflow-spatial:arm64 .
```

> O build compila o GDAL a partir do código-fonte e leva bastante tempo. É necessário BuildKit (padrão nas versões atuais do Docker).

## Parâmetros de build (`ARG`)

### Versões

| ARG | Padrão | Descrição |
|---|---|---|
| `PYTHON_VERSION` | `3.12` | Versão do Python da imagem base |
| `DEBIAN_VERSION` | `trixie` | Codinome do Debian da imagem base |
| `AIRFLOW_VERSION` | `2.11.2` | Versão do Apache Airflow |
| `AIRFLOW_PLUGINS` | `celery,elasticsearch,oracle,...` | Extras instalados com o Airflow (`apache-airflow[...]`) |
| `OSGEO_GDAL_VERSION` | `3.12.4` | Versão do GDAL compilado |
| `APACHE_ARROW_VERSION` | `26.0` | Versão `<major>.<minor>` do Apache Arrow/Parquet (veja [Apache Arrow](#apache-arrow)) |

### Caminhos e usuário

| ARG | Padrão | Descrição |
|---|---|---|
| `AIRFLOW_INSTALL_DIR` | `/var/lib/airflow` | Diretório do virtualenv; o `AIRFLOW_HOME` fica em `<dir>/home` |
| `ORACLE_INSTANTCLIENT_DIR` | `/opt/oracle` | Diretório do Oracle Instant Client |
| `AIRFLOW_RUN_DIR` | `/run/airflow` | Diretório dos arquivos de PID e do passwd do nss_wrapper |
| `AIRFLOW_USER` | `50000` | UID padrão do container (veja [Usuário e permissões](#usuário-e-permissões)) |

### Integridade dos downloads

| ARG | Descrição |
|---|---|
| `ORACLE_BASICLITE_SHA256_X64` / `ORACLE_SDK_SHA256_X64` | SHA256 dos zips do Instant Client para amd64 |
| `ORACLE_BASICLITE_SHA256_ARM64` / `ORACLE_SDK_SHA256_ARM64` | SHA256 dos zips do Instant Client para arm64 |
| `APACHE_ARROW_SIGNER_FINGERPRINTS` | Fingerprints (separados por espaço) das chaves GPG autorizadas a assinar o repositório apt do Apache Arrow |

O build falha se algum hash ou fingerprint não conferir. Veja [Atualização de versões](#atualização-de-versões).

## Etapas do estágio `build`

1. **Dependências de compilação**: `build-essential`, `cmake`, `wget`, `gnupg`, etc.
2. **Oracle Instant Client** (basiclite + SDK)
   - Baixa os zips da arquitetura atual (`x64` ou `arm64`) e confere o SHA256 de cada um.
   - Extrai em `ORACLE_INSTANTCLIENT_DIR` e registra o diretório no `ld.so.conf.d`.
   - Cria o link `libaio.so.1`, que o Instant Client procura e que no Debian trixie se chama `libaio.so.1t64`.
3. **Repositório do Apache Arrow**
   - Baixa o arquivo `KEYS` de `downloads.apache.org` e exporta para `/usr/share/keyrings/apache-arrow.gpg` **somente** as chaves listadas em `APACHE_ARROW_SIGNER_FINGERPRINTS`.
   - Configura o repositório em `/etc/apt/sources.list.d/apache-arrow.sources` com `Signed-By` apontando para esse keyring: o apt passa a validar a assinatura do repositório.
   - Cria `/etc/apt/preferences.d/apache-arrow`, que fixa **todos** os pacotes `libarrow*` e `libparquet*` em `APACHE_ARROW_VERSION.*` (inclusive dependências indiretas, como o `libarrow-acero-dev`).
   - Instala os headers do Arrow/Parquet e as demais dependências do GDAL.
4. **GDAL**
   - Baixa o tarball e o `.md5` publicados pela OSGeo e confere com `md5sum -c`.
   - Compila com drivers opcionais habilitados e suporte a Oracle, instalando em `/usr/gdal`.
5. **Virtualenv do Airflow** em `AIRFLOW_INSTALL_DIR/venv`
   - Airflow com os extras de `AIRFLOW_PLUGINS`, usando o arquivo de constraints oficial da versão.
   - Pacotes de [requirements.txt](../requirements.txt), também sob as constraints do Airflow.
   - Bindings Python do GDAL na mesma versão do GDAL compilado (`gdal-config --version`).

Todos os `RUN` usam `bash -o pipefail`: qualquer comando que falhe dentro de um pipe interrompe o build.

## Etapas do estágio `release`

1. Instala as bibliotecas de runtime (GDAL, SpatiaLite, KML, etc.), `tini` e `libnss-wrapper`.
2. Copia o keyring, o `.sources` e o arquivo de preferências do Arrow do estágio `build` e instala as bibliotecas de runtime do Arrow/Parquet. Os nomes desses pacotes são calculados a partir de `APACHE_ARROW_VERSION` (veja abaixo).
3. Copia `/usr/gdal`, o virtualenv, o Oracle Instant Client e os scripts de [scripts/](../scripts/).
4. Registra `/usr/gdal/lib` no `ldconfig`, ajusta permissões dos diretórios e inclui o [airflow-init.sh](../scripts/airflow-init.sh) no `/etc/bash.bashrc`.
5. Restaura o shell padrão (`/bin/sh -c`), para que imagens derivadas não herdem o `bash -o pipefail`.
6. Define o nss_wrapper, o usuário e o entrypoint.

### Variáveis de ambiente da imagem final

| Variável | Valor | Uso |
|---|---|---|
| `AIRFLOW_INSTALL_DIR` | `/var/lib/airflow` | Raiz da instalação |
| `AIRFLOW_HOME` / `HOME` | `/var/lib/airflow/home` | Home do Airflow e do usuário |
| `AIRFLOW_RUN_DIR` | `/run/airflow` | Arquivos de PID e passwd do nss_wrapper |
| `GDAL_DATA` | `/usr/gdal/share/gdal` | Arquivos de dados usados pelos drivers do GDAL (schemas XSD, templates de DXF/DGN, etc.) |
| `PATH` | inclui `/usr/gdal/bin` | Utilitários do GDAL (`gdalinfo`, `ogr2ogr`, ...) |
| `NSS_WRAPPER_PASSWD`, `NSS_WRAPPER_GROUP`, `LD_PRELOAD` | — | nss_wrapper (veja abaixo) |

## Usuário e permissões

- O container roda por padrão com o **UID 50000 e GID 0**, sem conta criada no `/etc/passwd`.
- `AIRFLOW_HOME` e `AIRFLOW_RUN_DIR` pertencem ao grupo 0 com permissão `g=u`. Assim, **qualquer UID com GID 0** consegue gravar neles, o que atende ao OpenShift (UID aleatório, GID 0) sem precisar de `securityContext`.
- O virtualenv, o GDAL e o Oracle Instant Client continuam pertencendo ao root: o usuário da aplicação não consegue alterar binários e bibliotecas.
- **nss_wrapper**: como o UID não existe no `/etc/passwd`, o entrypoint gera `$AIRFLOW_RUN_DIR/passwd` (cópia do passwd + usuário `airflow` com o UID atual). As variáveis `NSS_WRAPPER_*` e `LD_PRELOAD` estão no `ENV` da imagem, então o nome do usuário é resolvido também em `docker exec`.
  - O arquivo já é criado no build (cópia do `/etc/passwd`, grupo 0 com permissão de escrita, como o resto do `AIRFLOW_RUN_DIR`), para que os usuários sejam resolvidos antes de o entrypoint rodar. Qualquer UID do OpenShift consegue sobrescrevê-lo.
  - Se o `AIRFLOW_RUN_DIR` (ou o `/run`) for montado como volume (`emptyDir`/`tmpfs`), o arquivo do build fica oculto e o log mostra duas linhas `NWRAP_ERROR ... Unable to open '/run/airflow/passwd'` na inicialização. Elas são inofensivas: o entrypoint gera o arquivo em seguida (o volume precisa ser gravável pelo grupo 0, como já é necessário para os PIDs).
  - O `/etc/passwd` **não** é tornado gravável, de propósito: isso permitiria ao usuário da aplicação escalar para root.

Para rodar com outro UID: `docker run --user 12345:0 ...` (mantenha o GID 0).

## Entrypoint e comandos

O `ENTRYPOINT` é `tini -- /docker-entrypoint.sh` e o `CMD` padrão é `standalone`. O [docker-entrypoint.sh](../scripts/docker-entrypoint.sh) aceita:

| Comando | O que faz |
|---|---|
| `standalone` / `dev` | `airflow standalone` (webserver, scheduler e triggerer no mesmo container) |
| `init` / `initdb` | Aguarda o banco e executa `airflow db migrate` |
| `webserver`, `scheduler`, `triggerer` | Aguarda o banco, verifica as migrações e inicia o componente |
| `worker` | Aguarda o banco e inicia o worker Celery |
| `flower` | Inicia o Flower em `:5555/flower` |
| `version`, `info` | Informações do Airflow |
| qualquer outro | Executado diretamente (ex.: `docker run <imagem> bash`) |

A espera pelo banco usa a conexão configurada no próprio Airflow (`airflow.settings`), sem expor a connection string na linha de comando.

Se `AIRFLOW_EXTRA_REQUIREMENTS_FILE` apontar para um arquivo legível, os pacotes dele são instalados com `pip install --user` a cada inicialização. Prefira incluir dependências no [requirements.txt](../requirements.txt) e reconstruir a imagem: a instalação em runtime não é verificada nem reproduzível.

## Healthcheck

A imagem não define `HEALTHCHECK`; ele é configurado no orquestrador chamando o [docker-healthcheck.sh](../scripts/docker-healthcheck.sh) com o nome do componente:

```yaml
healthcheck:
  test: ["CMD", "/docker-healthcheck.sh", "webserver"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 30s
```

Componentes aceitos: `webserver`, `scheduler`, `worker`, `triggerer` e `flower`.

## Atualização de versões

### Oracle Instant Client

A versão está **fixa nas URLs** do `RUN` do Oracle (`1932000` / `19.32.0.0.0dbru`), não em um `ARG`.

1. Atualize as duas URLs (basiclite e SDK).
2. Copie os novos SHA256 das páginas de download da Oracle e atualize os quatro ARGs `ORACLE_*_SHA256_*`:
   - x64: https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
   - arm64: https://www.oracle.com/database/technologies/instant-client/linux-arm-aarch64-downloads.html
3. Atualize o comentário de versão acima dos ARGs.

### GDAL

Altere apenas `OSGEO_GDAL_VERSION`. O `.md5` é baixado junto com o tarball, então não há hash para manter. Confira se novas versões exigem dependências adicionais (veja as notas de release do GDAL).

### Apache Arrow

A versão é controlada pelo ARG `APACHE_ARROW_VERSION`, no formato `<major>.<minor>` (ex.: `26.0`):

- **Estágio `build`**: um arquivo de preferências do apt (`Pin-Priority: 1001`) fixa todos os pacotes `libarrow*` e `libparquet*` em `<major>.<minor>.*`. O build recebe a correção mais recente dessa versão (ex.: `26.0.1`), mas nunca uma versão principal nova. Um lançamento do Arrow 27 não afeta a imagem.
- **Estágio `release`**: o nome das bibliotecas de runtime contém a versão da ABI, calculada como `major * 100 + minor` (`26.0` → `libarrow-compute2600`, `libarrow-dataset2600`, `libparquet2600`). Elas são sempre compatíveis com a versão usada na compilação do GDAL.
- O build falha se o valor não estiver no formato `<major>.<minor>`.

Para mudar de versão:

1. Altere `APACHE_ARROW_VERSION` (ou passe `--build-arg APACHE_ARROW_VERSION=27.0`).
2. Confira se a versão existe no repositório do Debian em uso:

   ```bash
   curl -sL https://packages.apache.org/artifactory/arrow/debian/dists/trixie/main/binary-amd64/Packages \
     | grep -A3 '^Package: libarrow-dev$' | grep '^Version'
   ```

3. Confira se a versão do GDAL é compatível com a nova versão do Arrow.

O repositório mantém as versões antigas, então uma versão fixada continua disponível depois de novos lançamentos.

Se o repositório passar a ser assinado por outra chave (troca de release manager), o `apt-get update` falha com erro de assinatura. Confira a nova chave no [KEYS](https://downloads.apache.org/arrow/KEYS) e adicione o fingerprint em `APACHE_ARROW_SIGNER_FINGERPRINTS`.

Para descobrir qual chave assina o repositório atualmente:

```bash
curl -s https://packages.apache.org/artifactory/arrow/debian/dists/trixie/InRelease | gpg --verify 2>&1 | grep -i 'key'
```

### Airflow e Python

Altere `AIRFLOW_VERSION` e/ou `PYTHON_VERSION`. As constraints oficiais são selecionadas automaticamente pela combinação das duas versões; confira se essa combinação é suportada pelo Airflow.

## Acessos de rede durante o build

| Host | Uso |
|---|---|
| `deb.debian.org` | Pacotes do Debian |
| `download.oracle.com` | Oracle Instant Client |
| `downloads.apache.org` | Chaves GPG do Apache Arrow |
| `packages.apache.org` | Repositório apt do Apache Arrow |
| `download.osgeo.org` | Código-fonte do GDAL |
| `raw.githubusercontent.com` | Arquivo de constraints do Airflow |
| `pypi.org` / `files.pythonhosted.org` | Pacotes Python |

Em ambientes com proxy ou firewall, esses hosts precisam estar liberados.

## Lint

```bash
docker build --check .
docker run --rm -i hadolint/hadolint < Dockerfile
```

Avisos conhecidos e aceitos:

| Linter | Aviso | Motivo |
|---|---|---|
| `docker build --check` | `SecretsUsedInArgOrEnv` em `NSS_WRAPPER_PASSWD` | Falso positivo: o nome é exigido pelo nss_wrapper e o valor é um caminho de arquivo |
| hadolint | DL3008 / DL3013 | Versões de apt e pip sem pin, de propósito |
| hadolint | DL3003 | `cd` no build do GDAL |
| hadolint | SC1091 | `source` do virtualenv |

## CI

O workflow [.github/workflows/docker.image.yml](../.github/workflows/docker.image.yml) é disparado manualmente (`workflow_dispatch`) e:

1. Constrói a imagem para `linux/amd64` com os ARGs da matriz (`AIRFLOW_VERSION`, `PYTHON_VERSION`, `DEBIAN_VERSION`).
2. Publica em `docker.io/ndscprm/airflow` com as tags `<airflow>-py<python>-spatial` e `<airflow>-py<python>-spatial-<data>`.
3. Analisa CVEs com Docker Scout e envia o resultado (SARIF) para o GitHub.
