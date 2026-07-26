# Referência de Scripts

[← Índice](README.md)

Todos os scripts do repositório são idempotentes, com checagens de
pré-voo, e não fazem nenhuma ação destrutiva por padrão (as poucas que
são destrutivas exigem confirmação explícita ou uma flag adicional). O
bit de execução é versionado no próprio git — `git clone` em Linux já
entrega tudo executável.

| Script | Para que serve | Uso |
|---|---|---|
| [`setup.sh`](#setupsh) | Provisionamento inicial (segredos, certs, `.env`) | Etapa 1, uma vez |
| [`deploy.sh`](#deploysh) | Sobe/atualiza a stack | Etapa 1 em diante, a cada deploy |
| [`manage.sh`](#managesh) | Console de gerenciamento do dia a dia | Operação contínua |
| [`scripts/configure_ldap.sh`](#scriptsconfigure_ldapsh) | Federação com o AD | Etapa 3 |
| [`scripts/install_console_menu.sh`](#scriptsinstall_console_menush) | Menu automático no login | Opcional, uma vez |
| [`scripts/backup.sh`](#scriptsbackupsh) | Backup lógico do Postgres | Etapa 5, via cron |
| [`scripts/restore_test.sh`](#scriptsrestore_testsh) | Drill de restauração | Etapa 5, sob demanda |

---

## `setup.sh`

Prepara o terreno: valida Docker/Compose/openssl, cria `secrets/` e
`certs/`, gera o `.env` (interativo) e os segredos de 32 caracteres.
**Nunca sobrescreve** segredo já existente — para reconfigurar do zero,
apague o `.env`/arquivo específico antes.

```bash
./setup.sh                 # interativo
./setup.sh --yes           # aceita os padrões sem perguntar (CI/automação)
./setup.sh --self-signed   # forca modo homologacao (Traefik autoassinado),
                             # pula a pergunta de Let's Encrypt mesmo com --yes
./setup.sh --no-anim       # desativa a animação de abertura
```

Segredos gerados são **alfanuméricos puros** (sem `+`, `/`, `=`) de
propósito: segredos base64 "crus" quebram testes com `curl -d` sem
`--data-urlencode` (ver nota na [Etapa 2](02-configuracao-keycloak.md)).

Durante a execução, pergunta também se você quer habilitar o
[Portainer](#portainer) — grava a resposta em `ENABLE_PORTAINER` no
`.env` — e se quer ativar Let's Encrypt real (ver [Traefik](#traefik)).

> **Não há mais arquivo de certificado pra gerenciar.** Desde a troca do
> proxy reverso de Nginx para [Traefik](#traefik), o TLS é gerenciado
> automaticamente (autoassinado em homologação, Let's Encrypt em
> produção) — a antiga pegadinha de certificado desatualizado após troca
> de domínio (CN antigo preso em `nginx/certs/`) **não existe mais nessa
> forma**: o Traefik não fixa um certificado por domínio em disco no modo
> homologação, então não há arquivo pra ficar desatualizado.
>
> O que **continua valendo** é o HSTS: o navegador pode continuar
> recusando o acesso a um domínio que ele já visitou antes com HTTPS,
> **sem oferecer o botão "Avançado → Continuar"**, mesmo com a stack
> saudável — o middleware `security-headers` do Traefik envia
> `Strict-Transport-Security` (`max-age=63072000` ≈ 2 anos, ver
> [Traefik](#traefik)) e o Chrome memoriza isso por domínio. Não é bug da
> stack, é o navegador cumprindo HSTS à risca. Pra testar com certificado
> autoassinado nesse cenário, limpe a política em
> `chrome://net-internals/#hsts` → "Delete domain security policies" →
> informe o domínio. Isso deixa de ser um problema assim que o
> certificado for confiável nativamente (Let's Encrypt em produção).

---

## `deploy.sh`

Roda as checagens de pré-voo, puxa a imagem do Keycloak já construída e
escaneada pelo CI (ver [CI/CD e Registry](ci-cd.md)), sobe a stack e
aguarda os contêineres ficarem `healthy`. Ao final, mostra o painel de
serviços (status ao vivo, URL, IP:porta) e um resumo do deploy. Se algo
falhar, imprime os últimos logs automaticamente.

```bash
./deploy.sh                  # modo produção: pull do registry + up -d
./deploy.sh --build           # builda a imagem localmente (dev/homologação,
                               # sem depender do registry)
./deploy.sh --no-pull         # usa a imagem já em cache local, sem baixar de novo
./deploy.sh --configure-ldap  # roda scripts/configure_ldap.sh após a stack subir
./deploy.sh --logs            # segue os logs após o deploy ter sucesso
./deploy.sh --no-menu         # nao abre o ./manage.sh ao final (so' o deploy)
./deploy.sh --down            # derruba a stack (preserva o volume do Postgres)
./deploy.sh --down --purge    # derruba E apaga o volume do Postgres (destrutivo!)
./deploy.sh --timeout 300     # tempo máximo de espera pelos healthchecks (padrão 240s)
./deploy.sh --help            # todas as opções
```

O Portainer (se `ENABLE_PORTAINER=true` no `.env`) é ativado/desativado
automaticamente via profile do Compose — não precisa de flag para isso.

Em **sessão interativa** (terminal de verdade), ao final de um deploy com
sucesso o [`./manage.sh`](#managesh) abre automaticamente, pra você já
cair direto no console de gerenciamento. Use `--no-menu` pra desativar
numa execução específica. Em automação/CI (sem terminal associado) isso
nunca acontece — a checagem é feita via `[ -t 0 ] && [ -t 1 ]`, então
scripts e pipelines não ficam presos esperando um menu.

---

## `manage.sh`

Console interativo (estilo o console de setup do TrueNAS) para operar a
stack no dia a dia, sem precisar decorar comandos `docker compose`:

```bash
./manage.sh
```

A cada tela, mostra o banner e o painel de serviços com **status ao
vivo** (consultado na hora — reflete o estado real, não uma foto de
quando o deploy terminou):

| # | Opção | O que faz |
|---|---|---|
| 1 | Ver logs | Escolhe um serviço (ou todos) e segue os logs (`Ctrl+C` volta ao menu) |
| 2 | Reiniciar um serviço | `docker compose up -d --force-recreate` num serviço específico ou em todos — recria o contêiner (não é um `restart` simples), então também aplica qualquer mudança feita no `.env` desde a última subida |
| 3 | Parar a stack | `docker compose stop` — mantém os dados, sobe rápido de novo |
| 4 | Iniciar a stack | `docker compose start` (contêineres já criados) |
| 5 | Atualizar | Roda `./deploy.sh` (pull da imagem mais recente + redeploy) |
| 6 | Backup agora | Roda `scripts/backup.sh` |
| 7 | Testar restauração de backup | Roda `scripts/restore_test.sh` |
| 8 | Configurar LDAP/AD | Roda `scripts/configure_ldap.sh` |
| 9 | Uso de recursos | `docker stats` **ao vivo** (estilo `htop`) de todos os contêineres — atualiza continuamente até `Ctrl+C` |
| 10 | Shell num contêiner | Abre um shell interativo (`bash`, com fallback pra `sh`) — útil para debug pontual |
| 11 | Atualizar esta tela | Redesenha o painel sem executar nada |
| 0 | Sair | Fecha o menu (a stack continua rodando normalmente) |

Só para uso interativo num terminal de verdade (não roda em CI/automação
— para isso use `deploy.sh` direto). Ativa automaticamente o profile do
Portainer (se habilitado) para que Parar/Iniciar/Reiniciar cubram o
Portainer também, não só o Keycloak/Postgres/Traefik.

> **`docker compose restart` vs `docker compose up -d` — pegadinha real**:
> `restart` reusa o contêiner que já existe, com o ambiente que ele já
> tinha carregado na memória desde que subiu — **não relê o `.env`**. Se
> você editou o `.env` (ex.: trocou `KC_HOSTNAME`) e só der `restart`, a
> mudança **não** é aplicada, mesmo o contêiner reiniciando sem erro. Use
> sempre `docker compose up -d` (ou `./deploy.sh`, ou a opção 2 do
> `manage.sh`) depois de editar o `.env` — `up -d` recria o contêiner só
> se algo no config efetivo mudou (senão é um no-op seguro). Achado real
> em produção: trocar `KC_HOSTNAME` no `.env` e dar `restart` deixou o
> Keycloak redirecionando pro domínio antigo indefinidamente.

### `scripts/install_console_menu.sh`

Por padrão o `manage.sh` só aparece quando você roda ele manualmente.
Este script faz o menu aparecer **automaticamente toda vez que alguém
logar na VM** (via SSH ou no console local do hypervisor/nuvem):

```bash
sudo ./scripts/install_console_menu.sh              # instala
sudo ./scripts/install_console_menu.sh --uninstall   # remove
```

Como funciona: instala um hook em
`/etc/profile.d/keycloak-manage-menu.sh`, que o Linux roda
automaticamente em todo **shell de login interativo** — cobre SSH e o
console local com o mesmo mecanismo, sem precisar de duas instalações
separadas. Escolher **"0) Sair"** no menu não fecha a sessão: devolve o
terminal pro shell normal (é um subprocesso, não substitui o shell).

**Sessões não-interativas continuam normais**: `ssh vm "comando"`, `scp`,
`rsync`, Ansible etc. não passam por `/etc/profile.d` — só shells de
*login* interativos disparam o hook. Confirmado com um teste real (SSH de
verdade contra um contêiner com `sshd`, chave pública) antes deste script
ser incorporado ao repositório: login interativo mostra o menu e depois
cai no shell normal; `ssh vm "echo x"` não mostra nada. Para pular o menu
numa sessão específica sem desinstalar:
```bash
ssh usuario@vm bash --noprofile --norc
```

> Requer `sudo` porque grava em `/etc/profile.d/` (fora deste
> repositório, afeta todo login na VM). É o único script deste projeto
> que mexe em configuração do sistema — todos os outros vivem inteiramente
> dentro da pasta do repositório.

---

## Traefik

Proxy reverso e único ponto de entrada externo da stack (porta host
`80`/`443`) — substituiu o Nginx. Descobre o serviço `keycloak`
automaticamente via labels no `docker-compose.yml` (provider Docker do
próprio Traefik, lendo o socket do Docker em modo somente leitura), sem
nenhum arquivo de configuração de proxy pra manter.

**Três modos de TLS**, verificados nesta ordem de prioridade pelo
`setup.sh` a cada execução (idempotente — pode rodar de novo a qualquer
momento pra reavaliar):

| Modo | Como ativa | Certificado |
|---|---|---|
| Certificado próprio (CA da prefeitura) | Copiar `fullchain.pem`/`privkey.pem` para `certs/tls/` e rodar `./setup.sh` de novo | O que você forneceu — sem ACME, sem DNS público |
| Produção com Let's Encrypt | `COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml` no `.env` (setup.sh grava isso ao responder "sim" pra Let's Encrypt) | Let's Encrypt via ACME, emitido e renovado sozinho |
| Homologação/rede interna (padrão) | Nada a fazer — é o padrão quando nenhum dos dois acima se aplica | Autoassinado, gerado automaticamente pelo próprio Traefik |

`docker-compose.prod.yml` é um **overlay**: só adiciona ao `traefik` as
flags de ACME e o volume nomeado `traefik-certificates` (onde o
certificado Let's Encrypt fica guardado, fora do repositório), e ao
`keycloak` o label que aponta pro resolver ACME. Não duplica nada do
compose base. Produção real com Let's Encrypt **exige DNS público**
resolvendo `KC_HOSTNAME_FQDN` para esta VM, com as portas 80/443
alcançáveis da internet (é onde o desafio ACME acontece) — sem isso a
emissão do certificado falha. Se o domínio só existe na rede interna da
prefeitura (`sso.papermoon.cloud` hoje resolve pra um IP privado), esse
modo **não é viável** sem expor a VM publicamente — use o certificado
próprio nesse caso.

### Certificado próprio (CA interna/corporativa da prefeitura)

Alternativa ao Let's Encrypt pra quem tem um certificado emitido pela CA
da própria prefeitura (cenário comum em rede interna, sem DNS público).
Mecanismo: o Traefik roda com o **provider "file"** sempre ativo
(`--providers.file.directory=/etc/traefik/dynamic-certs`, observando a
pasta continuamente), além do provider Docker. O `setup.sh`, ao detectar
`certs/tls/fullchain.pem` e `certs/tls/privkey.pem`, gera
`traefik/dynamic-certs/tls.yml`:
```yaml
tls:
  certificates:
    - certFile: /certs/tls/fullchain.pem
      keyFile: /certs/tls/privkey.pem
```
O Traefik registra esse certificado na store de TLS e passa a servi-lo
por **SNI** pra qualquer conexão em `sso.papermoon.cloud` — não precisa
de label extra no `keycloak` nem de flag no `deploy.sh`, é automático.
Sem esse arquivo, o Traefik cai de volta no certificado autoassinado
próprio (`CN=TRAEFIK DEFAULT CERT`).

Igual ao antigo comportamento do Nginx, o `setup.sh` confere se o `CN`
do certificado bate com `KC_HOSTNAME_FQDN` e avisa em caso de
descompasso — mas **não sobrescreve** os arquivos automaticamente
(mesma filosofia dos segredos).

> **Achado real ao implementar isso**: a checagem de CN usava
> `sed -E 's#.*CN\s*=\s*##'`, que pega tudo depois de `CN=` **até o fim
> da linha** — funciona pra um `subject=CN=x` isolado, mas quebra pra
> qualquer certificado real de CA, que quase sempre tem mais campos
> depois (`subject=CN=x, O=Prefeitura, C=BR`): o valor extraído virava
> `x, O=Prefeitura, C=BR` inteiro, e a comparação com `KC_HOSTNAME_FQDN`
> dava falso-positivo de "domínio não bate" mesmo com o certificado
> certo. Corrigido parando no próximo campo:
> `sed -E 's#.*CN\s*=\s*##; s#,.*##'`. Testado com um certificado real
> de subject multi-campo antes de considerar corrigido — o teste ingênuo
> (só `CN=x` isolado) não pegava esse bug.
>
> Validado ao vivo de ponta a ponta: certificado de teste gerado com
> `subject=CN=sso.papermoon.cloud, O=Prefeitura (CA de teste)`, colocado
> em `certs/tls/`, `setup.sh` detectou e confirmou o CN batendo,
> `docker compose up -d --force-recreate traefik` e o `openssl s_client`
> confirmou o Traefik servindo **esse** certificado (não mais
> `TRAEFIK DEFAULT CERT`) — depois removido, confirmando que o Traefik
> volta ao autoassinado sozinho. Testado nos dois sentidos, mais o caso
> de CN errado (detecta e avisa corretamente).

Paridade de segurança com o antigo `nginx.conf`: um middleware Traefik
(`security-headers`, aplicado via label no `keycloak`) envia os mesmos
três headers que o Nginx enviava — `Strict-Transport-Security`
(HSTS), `X-Frame-Options: SAMEORIGIN` (não `DENY` — o Keycloak usa um
iframe same-origin pro "status iframe" de SSO/SLO) e
`X-Content-Type-Options: nosniff`. O antigo `client_max_body_size 20m`
do Nginx não tem equivalente porque não é necessário: o Traefik não
impõe limite de corpo de requisição por padrão.

### Dois achados reais ao migrar de Nginx pra Traefik

Encontrados rodando a stack de verdade (não só revisão de código) —
documentados aqui pra não serem redescobertos:

> **1. Versão do Traefik importa** — `traefik:v3.3` entrou em loop de
> erro (`Failed to retrieve information of the docker client and server
> host`, mensagem vazia) num ambiente com Docker Engine recente: o
> cliente Docker embutido nessa versão do Traefik não negocia direito
> com uma API mais nova (`1.55`) do daemon. `traefik:latest` (resolveu
> pra `3.7.9`) funcionou de primeira. Por isso a imagem fica **travada
> em `traefik:v3.7.9`** (versão testada), não em `latest` — se
> atualizar, teste de verdade antes de considerar concluído, esse tipo
> de bug não aparece numa revisão só de código.

> **2. `traefik.docker.network` é obrigatório com múltiplas redes** — o
> `keycloak` está em duas redes Docker (`frontend` e `backend`, essa
> última isolada). Sem informar explicitamente qual delas o Traefik deve
> usar pra rotear, a escolha não é determinística (mapas em Go não têm
> ordem garantida) — às vezes acerta a rede `frontend` (alcançável),
> às vezes a `backend` (isolada, inalcançável). Sintoma real: a stack
> respondia normalmente por alguns minutos e então travava (timeout),
> com todos os contêineres continuando `healthy` — nenhum sinal óbvio de
> problema em `docker compose ps`. Confirmado via `netstat` dentro do
> contêiner do Traefik: conexão presa em `SYN_SENT` contra o IP da rede
> errada. Corrigido com o label
> `traefik.docker.network=keycloak_frontend` no `keycloak` **e** nomes
> fixos pras redes (`name: keycloak_frontend` / `name: keycloak_backend`
> no `docker-compose.yml`) — sem o nome fixo, clonar o repositório numa
> pasta com nome diferente mudaria o prefixo que o Compose gera
> automaticamente, e o label pararia de bater silenciosamente. Validado
> com requisições espaçadas em ~40s por alguns minutos e um redeploy
> completo do zero, pra garantir que não era coincidência.

O `deploy.sh` faz uma checagem de roteamento pós-deploy (`curl` com
retry contra `/realms/master/.well-known/openid-configuration`) — se ela
avisar que o roteamento não respondeu, comece a investigar por aqui
(`docker compose logs traefik` e o label acima).

---

## Portainer

Gerenciador visual do Docker, opcional. Ativado perguntando no
`setup.sh` (grava `ENABLE_PORTAINER` no `.env`) ou editando o `.env`
manualmente.

> **Atenção de segurança**: o Portainer precisa de acesso de leitura e
> escrita ao socket do Docker do host pra funcionar — isso equivale a
> acesso root na VM (quem controla o Docker controla todos os
> contêineres, inclusive o do Postgres). Por isso o bind padrão é
> `PORTAINER_BIND=127.0.0.1` — só acessível via SSH tunnel ou VPN da
> prefeitura:
> ```bash
> ssh -L 9443:127.0.0.1:9443 usuario@vm-da-prefeitura
> # depois acesse https://localhost:9443 no seu navegador
> ```
> Só mude `PORTAINER_BIND` para `0.0.0.0` (expõe na rede) se o firewall
> da prefeitura já filtrar quem chega na porta 9443 — nunca exponha
> direto na internet.

No primeiro acesso, o Portainer pede pra você criar o usuário admin dele
(senha própria, separada da do Keycloak) e usa um certificado
autoassinado que ele mesmo gera — o aviso de segurança do navegador
nesse primeiro acesso é esperado.

A imagem oficial do Portainer é baseada em `scratch` (sem shell, sem
`wget`/`curl`) — por isso ela não tem um `HEALTHCHECK` do Docker; o
`deploy.sh`/`manage.sh` tratam a ausência de healthcheck como "contêiner
rodando normalmente".

---

## `scripts/configure_ldap.sh`

Automatiza a [Etapa 3](03-federacao-ad.md) (federação com o Active
Directory) via `kcadm.sh` — CLI administrativo do próprio Keycloak,
chamado por dentro do contêiner, sem expor nenhuma porta administrativa
extra. Idempotente: rodar de novo atualiza a configuração existente em
vez de duplicar.

```bash
./deploy.sh --configure-ldap        # roda depois da stack subir healthy
./scripts/configure_ldap.sh         # ou direto, se a stack já estiver no ar
./scripts/configure_ldap.sh --yes   # aceita os padrões sem perguntar
```

Pergunta interativamente: realm, Connection URL, Bind DN, senha da conta
de bind (gravada em `secrets/ldap_bind_password.txt`, nunca em texto
plano no `.env`), Users DN e Groups DN — com valores padrão derivados de
`AD_DOMAIN`/`AD_DC_HOSTNAME` do `.env`. Cria o provider LDAP (vendor AD,
`READ_ONLY`, LDAPS) e o `group-ldap-mapper`, depois dispara o
"Synchronize all users".

> Os portões de validação completos (Test Connection, Test
> Authentication, login real de um servidor) continuam manuais — o
> script cobre a criação/atualização da configuração, não substitui a
> validação final. Ver [Etapa 3](03-federacao-ad.md#portão-de-validação).

Se o realm informado ainda não existir, o script cria um realm vazio
(sem grupos/clients) e avisa que a [Etapa 2](02-configuracao-keycloak.md)
ainda precisa ser feita à parte.

---

## `scripts/backup.sh`

Backup lógico diário do banco do Keycloak (via `pg_dump`), com
compressão, checagem de erro e retenção configurável.

```bash
./scripts/backup.sh
BACKUP_DIR=/mnt/outro/lugar RETENTION_DAYS=30 ./scripts/backup.sh
```

Uso recomendado via cron (ver [Etapa 5](05-golive-operacao.md)):
```
0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
```

Variáveis de ambiente: `BACKUP_DIR` (padrão `/mnt/backup_nfs`),
`RETENTION_DAYS` (padrão `14`).

---

## `scripts/restore_test.sh`

Drill de restauração: restaura o backup mais recente (ou um especificado)
num contêiner Postgres **descartável e isolado**, valida a integridade
dos dados, e remove o contêiner de teste ao final — sem tocar no banco de
produção em nenhum momento.

```bash
./scripts/restore_test.sh                       # usa o backup mais recente em $BACKUP_DIR
./scripts/restore_test.sh /caminho/para/dump.sql.gz
```

Sai com `PASS` e a contagem de tabelas restauradas se tudo der certo, ou
mensagem de erro clara se o dump estiver corrompido ou a restauração
falhar.
