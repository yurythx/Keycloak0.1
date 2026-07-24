# Runbook de Implantação — Keycloak SSO da Prefeitura

Documento operacional para a implantação do Keycloak (autenticação única da
prefeitura), com federação ao Active Directory via LDAPS e integração SSO
com Intranet (Django), GLPI e Zabbix.

**Regra de ouro:** nenhuma etapa avança sem que o **portão de validação**
anterior tenha passado. Se um portão falhar, pare, corrija a causa raiz e
repita a validação — não pule etapas.

## Scripts de automação (`./setup.sh`, `./deploy.sh` e `./manage.sh`)

O provisionamento inicial e a subida da stack (Etapa 1) são automatizados
por scripts na raiz do repositório — idempotentes, com checagens de
pré-voo e sem nenhuma ação destrutiva por padrão:

- **`./setup.sh`** — prepara o terreno: valida Docker/Compose/openssl, cria
  `secrets/`, `certs/`, `nginx/certs/`, gera `.env` (interativo) e os
  segredos de 32 caracteres, e opcionalmente um certificado autoassinado
  para homologação (`--self-signed`). Nunca sobrescreve segredo ou
  certificado já existente.
  ```bash
  ./setup.sh                 # interativo
  ./setup.sh --yes           # aceita os padrões sem perguntar (CI)
  ./setup.sh --self-signed   # gera cert de teste (NUNCA em produção)
  ```
- **`./deploy.sh`** — roda as checagens de pré-voo, puxa a imagem do
  Keycloak já construída e escaneada pelo CI, faz `up -d` (incluindo o
  Portainer, se habilitado) e aguarda os contêineres ficarem `healthy` (com
  timeout). Ao final, mostra um **painel de serviços** (nome, status, URL
  de acesso e IP:porta interno de cada contêiner) e um resumo do deploy. Se
  algo falhar, imprime os últimos logs automaticamente.
  ```bash
  ./deploy.sh                  # modo producao: pull do registry (KEYCLOAK_IMAGE) + up -d
  ./deploy.sh --build           # builda a imagem localmente (dev/homologacao)
  ./deploy.sh --no-pull         # usa a imagem ja em cache local, sem baixar de novo
  ./deploy.sh --configure-ldap  # roda scripts/configure_ldap.sh apos a stack subir
  ./deploy.sh --down           # derruba a stack (preserva o volume do DB)
  ./deploy.sh --down --purge   # derruba E apaga o volume do Postgres (destrutivo)
  ./deploy.sh --help           # todas as opções
  ```

> O bit de execução dos scripts é versionado no próprio git (modo 755
> forçado no índice), então `git clone` em Linux já entrega tudo
> executável. Se por algum motivo não estiver (ex.: baixou um .zip em vez
> de clonar), rode uma vez: `chmod +x setup.sh deploy.sh scripts/*.sh
> scripts/lib/*.sh`.

Os comandos manuais abaixo em cada etapa continuam documentados como
referência/fallback, mas o caminho recomendado é sempre `./setup.sh`
seguido de `./deploy.sh`.

### Portainer (opcional)

`./setup.sh` pergunta se quer subir o Portainer (gerenciador visual do
Docker) e grava a resposta em `ENABLE_PORTAINER` no `.env` — `./deploy.sh`
lê essa variável e ativa/desativa o serviço automaticamente a cada deploy
(profile do Compose, sem precisar lembrar de nenhuma flag).

> **Atenção de segurança**: o Portainer precisa de acesso de leitura e
> escrita ao socket do Docker do host pra funcionar — isso equivale a
> acesso root na VM (quem controla o Docker controla todos os contêineres,
> inclusive o do Postgres). Por isso o bind padrão é `PORTAINER_BIND=
> 127.0.0.1` — só acessível via SSH tunnel ou VPN da prefeitura:
> ```bash
> ssh -L 9443:127.0.0.1:9443 usuario@vm-da-prefeitura
> # depois acesse https://localhost:9443 no seu navegador
> ```
> Só mude `PORTAINER_BIND` para `0.0.0.0` (expõe na rede) se o firewall da
> prefeitura já filtrar quem chega na porta 9443 — nunca exponha direto na
> internet.

No primeiro acesso, o Portainer pede pra você criar o usuário admin dele
(senha própria, separada da do Keycloak) e usa um certificado autoassinado
que ele mesmo gera — o aviso de segurança do navegador nesse primeiro
acesso é esperado.

### Federação LDAP/AD automatizada (`scripts/configure_ldap.sh`)

Automatiza a Etapa 3 (federação com o Active Directory) via `kcadm.sh` (CLI
administrativo do próprio Keycloak, chamado por dentro do contêiner —
não expõe nenhuma porta administrativa extra). Idempotente: rodar de novo
atualiza a configuração existente em vez de duplicar.
```bash
./deploy.sh --configure-ldap        # roda depois da stack subir healthy
./scripts/configure_ldap.sh         # ou direto, se a stack ja estiver no ar
```
Pergunta interativamente realm, Connection URL, Bind DN, senha da conta de
bind (gravada em `secrets/ldap_bind_password.txt`, nunca em texto plano no
`.env`), Users DN e Groups DN — com valores padrão derivados de
`AD_DOMAIN`/`AD_DC_HOSTNAME` do `.env`. Cria o provider LDAP (vendor AD,
`READ_ONLY`, LDAPS) e o `group-ldap-mapper`, depois dispara o
"Synchronize all users". Os portões de validação completos (Test
Connection, Test Authentication, login real de um servidor) continuam os
da Etapa 3 abaixo — o script cobre a criação/atualização da configuração,
não substitui a validação manual final.

### Console de gerenciamento (`./manage.sh`)

Menu interativo (estilo o console de setup do TrueNAS) para operar a stack
no dia a dia, sem precisar decorar comandos `docker compose`:

```bash
./manage.sh
```

A cada tela, mostra o banner e o **painel de serviços com status ao vivo**
(o mesmo do fim do `deploy.sh`, mas consultado na hora — reflete o estado
real, não uma foto de quando o deploy terminou). Opções do menu:

| # | Opção | O que faz |
|---|---|---|
| 1 | Ver logs | Escolhe um serviço (ou todos) e segue os logs (`Ctrl+C` volta ao menu) |
| 2 | Reiniciar um serviço | `docker compose restart` num serviço específico ou em todos |
| 3 | Parar a stack | `docker compose stop` — mantém os dados, sobe rápido de novo |
| 4 | Iniciar a stack | `docker compose start` (containers já criados) |
| 5 | Atualizar | Roda `./deploy.sh` (pull da imagem mais recente + redeploy) |
| 6 | Backup agora | Roda `scripts/backup.sh` |
| 7 | Testar restauração de backup | Roda `scripts/restore_test.sh` |
| 8 | Configurar LDAP/AD | Roda `scripts/configure_ldap.sh` |
| 9 | Uso de recursos | `docker stats --no-stream` de todos os contêineres da stack |
| 10 | Shell num contêiner | Abre um shell interativo (`bash`, com fallback pra `sh`) num contêiner à escolha — útil para debug pontual |
| 11 | Atualizar esta tela | Redesenha o painel sem executar nada |
| 0 | Sair | Fecha o menu (a stack continua rodando normalmente) |

`manage.sh` é só para uso interativo num terminal de verdade (não roda em
CI/automação — para isso use `deploy.sh` direto). Assim como `deploy.sh`,
ele ativa automaticamente o profile do Portainer (se `ENABLE_PORTAINER=
true` no `.env`) para que Parar/Iniciar/Reiniciar cubram o Portainer
também, não só o Keycloak/Postgres/Nginx.

## CI/CD e Registry

**Build fora da VM**: a imagem do Keycloak não é mais construída na VM de
produção. O pipeline builda, valida e publica a imagem num registry; a VM
só faz `docker compose pull` (via `./deploy.sh`). Isso tira o processo de
build — e suas dependências (compiladores, cache, superfície de ataque) —
de cima do servidor que atende ao público.

Existem **dois pipelines equivalentes, um por plataforma** — cada uma só
processa o arquivo que reconhece, não há conflito em manter os dois no
mesmo repositório:

| | GitHub Actions | GitLab CI |
|---|---|---|
| Arquivo | `.github/workflows/ci.yml` | `.gitlab-ci.yml` |
| Registry | GitHub Container Registry (`ghcr.io`) | GitLab Container Registry (`$CI_REGISTRY_IMAGE`) |
| Credencial | `secrets.GITHUB_TOKEN` (automático) | `$CI_REGISTRY_USER`/`$CI_REGISTRY_PASSWORD` (automático) |
| Variável de imagem | `ghcr.io/<owner>/keycloak-sso` | `registry.<host>/<grupo>/<projeto>` |

**O que cada pipeline faz, em todo push/MR para a branch principal:**
1. **Lint** — `shellcheck` em todos os `.sh`, `hadolint` no `Dockerfile`,
   `docker compose config` para validar o compose (roda sem precisar de um
   daemon Docker de verdade).
2. **Build** — builda a imagem (roda inclusive em Pull Request/Merge
   Request, para pegar erro de build antes do merge).
3. **Scan de vulnerabilidades** — [Trivy](https://aquasecurity.github.io/trivy/)
   escaneia a imagem buildada em dois passos:
   - **Relatório HIGH+CRITICAL** (informativo, não bloqueia) — fica nos logs
     do CI pra acompanhamento.
   - **Gate de segurança** (bloqueia o pipeline) — falha **só** se houver
     `CRITICAL` com correção disponível.
   > **Por que não bloquear em HIGH também**: a maior parte dos achados
   > `HIGH` numa imagem do Keycloak está em bibliotecas Java *de terceiros
   > empacotadas pelo próprio vendor* (ex.: jackson-databind, netty,
   > drivers JDBC que nem usamos — o Keycloak empacota driver de SQL
   > Server mesmo rodando com Postgres). Exigir zero `HIGH` nessas
   > dependências transitivas travaria o deploy indefinidamente a cada
   > release do Keycloak, por algo fora do nosso controle direto. `CRITICAL`
   > é o piso não-negociável; `HIGH` fica **visível e monitorado**, não
   > bloqueante. Reavalie essa política periodicamente (ex.: a cada
   > atualização de versão do Keycloak) — decisão tomada em 2026-07-23 após
   > constatar que a versão `26.0` tinha `CRITICAL` real (CVE-2025-14813,
   > BouncyCastle) e vários `HIGH` específicos do próprio Keycloak
   > (autenticação/SAML) corrigidos ao subir para `26.7.0`.
4. **Push** (só em push/pipeline real na branch principal, nunca em PR/MR)
   — publica com duas tags: `latest` e `sha-<7 chars do commit>`. Numa tag
   `vX.Y.Z`, publica também essa tag de versão.

### GitHub Actions — detalhes específicos

**Visibilidade do pacote no GHCR** — decisão a tomar antes do primeiro
deploy em produção via pull:
- **Pacote público** (mais simples): a imagem não contém nenhum segredo da
  prefeitura (senhas ficam em `secrets/*.txt`, nunca na imagem) — tornar o
  pacote público é seguro e elimina a necessidade de autenticação na VM.
  Configurável em GitHub → seu perfil/org → Packages → `keycloak-sso` →
  Package settings → Change visibility.
- **Pacote privado**: mais conservador por política interna. Nesse caso, a
  VM precisa de `docker login` uma vez:
  ```bash
  echo "<PAT com escopo read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
  ```
  Gere o PAT em GitHub → Settings → Developer settings → Personal access
  tokens, com escopo mínimo `read:packages`.

**Permissões do `GITHUB_TOKEN`**: a pipeline usa o token automático do
GitHub Actions (nenhum secret manual necessário) para publicar no ghcr.io.
Se a organização/repositório tiver a permissão padrão do workflow
restrita a somente-leitura (Settings → Actions → General → Workflow
permissions), habilite "Read and write permissions" — sem isso o passo de
push falha com `403`.

### GitLab CI — detalhes específicos

**Runner privileged**: o job `build-scan-push` usa Docker-in-Docker
(`docker:27-dind`) para conseguir buildar imagens dentro do próprio CI. O
runner que executar esse job precisa estar configurado com `privileged =
true` (em `[runners.docker]` no `config.toml` do runner, ou na config do
runner no GitLab self-hosted). Sem isso o job falha tentando conversar com
o daemon Docker interno — é a causa mais comum de pipeline quebrada aqui.

**Registry do projeto**: `$CI_REGISTRY_IMAGE`, `$CI_REGISTRY_USER` e
`$CI_REGISTRY_PASSWORD` são providos automaticamente pelo GitLab para
qualquer projeto com o Container Registry habilitado (Settings → General →
Visibility → Container Registry) — nenhum secret manual necessário, mesmo
princípio do `GITHUB_TOKEN`.

### Reprodutibilidade em produção (vale para as duas plataformas)

Por padrão `KEYCLOAK_IMAGE_TAG=latest` (flutuante). Para "risco zero" de
uma atualização inesperada da imagem, trave em produção num `sha-xxxxxxx`
específico (o pipeline mostra a tag exata publicada no resumo da execução
— *Actions → run → Summary* no GitHub, no log do job `build-scan-push` no
GitLab):
```bash
# no .env da VM
KEYCLOAK_IMAGE=<registry usado>
KEYCLOAK_IMAGE_TAG=sha-1a2b3c4
```

---

## Etapa 0 — Pré-requisitos e Governança

### Ações
1. **Dimensionar a VM**: mínimo recomendado 8 vCPU / 16 GB RAM / 100 GB disco
   (o tuning do Postgres usa `shared_buffers=1GB` e o Keycloak roda com heap
   JVM de até 4 GB — some isso ao overhead do SO e margem de crescimento).
2. **Firewall**: liberar entrada apenas nas portas `80` e `443` na VM.
   Nenhuma outra porta (5432, 8080, 9000) deve ser alcançável de fora do host.
3. **Conta de serviço do AD**: solicitar à equipe do Active Directory a
   criação de `svc-keycloak` (ex: `CN=svc-keycloak,OU=ServiceAccounts,
   DC=prefeitura,DC=local`) com permissão **somente leitura** (bind/consulta),
   sem privilégios administrativos no domínio.
4. **Certificados**:
   - TLS público para `auth.prefeitura.gov.br`, emitido pela CA corporativa
     (`fullchain.pem` + `privkey.pem`).
   - CA raiz do Active Directory, exportada em `.pem`, para o truststore do
     Keycloak (necessária na Etapa 3, LDAPS).
5. **Janela de manutenção** aprovada e comunicada às áreas.
6. **Procedimento de rollback** documentado e aprovado (ex: `./deploy.sh
   --down` + restauração do snapshot da VM, ou reversão de DNS para o
   sistema de login anterior). `./deploy.sh --down` preserva o volume do
   Postgres por padrão; só use `--purge` se o objetivo for apagar os dados.

### Portão de Validação (Go/No-Go)
- [ ] Checklist acima assinado pelo responsável de infraestrutura do AD e
      pelo gestor da janela de manutenção.
- [ ] Certificados TLS e CA do AD já em mãos (não iniciar Etapa 1 sem eles).

---

## Etapa 1 — Provisionamento de Infraestrutura e Subida da Stack

### Ações
1. Provisionar a VM: Ubuntu Server 24.04 LTS (sem interface gráfica, sem
   aaPanel), Docker Engine + plugin Docker Compose v2.
2. Clonar o repositório na VM e rodar:
   ```bash
   ./setup.sh
   ```
   Isso cria `certs/`, `secrets/`, `nginx/certs/`, gera `.env` de forma
   interativa e os segredos de 32 caracteres em `secrets/*.txt`.
3. Copiar os certificados reais para dentro da estrutura criada pelo
   `setup.sh`:
   - `nginx/certs/fullchain.pem` e `nginx/certs/privkey.pem` (TLS público,
     emitido pela CA corporativa da prefeitura).
   - `certs/ad-ca.pem` (CA do AD — pode ser feito já aqui ou só na Etapa 3).
4. Subir a stack:
   ```bash
   ./deploy.sh
   ```
   Isso puxa a imagem do Keycloak já publicada pelo CI (GitHub ou GitLab,
   ver seção "CI/CD e Registry" acima) e sobe tudo — sem buildar nada na VM.
   Se o pipeline ainda não rodou nenhuma vez (primeiro deploy antes do
   primeiro `push` para `main`), use `./deploy.sh --build` para buildar
   localmente como alternativa temporária.

### Portão de Validação
- [ ] **Status dos contêineres**: `docker compose ps` mostra `keycloak_db`,
      `keycloak_server` e `keycloak_proxy` como `healthy`.
- [ ] **Isolamento de rede**: tentar conectar na porta 5432 a partir de outra
      máquina da rede local — a conexão deve ser **recusada** (Postgres não
      publica porta no host e a rede `backend` é `internal: true`).
- [ ] **Handshake TLS**: acessar `https://auth.prefeitura.gov.br/` no
      navegador — certificado válido, sem avisos de segurança, tela de login
      do Keycloak carrega.
- [ ] **Liveness/readiness (corrigido)**: `/health/live` e `/health/ready`
      ficam na *management port* (9000) do Keycloak por padrão — **não** na
      porta pública 8080/443, e essa porta **não é exposta** pelo Nginx
      (evita vazar `/metrics` publicamente). Validar a saúde real assim:
      ```bash
      docker compose ps          # coluna STATUS deve mostrar "healthy"
      docker inspect --format='{{json .State.Health}}' keycloak_server
      ```
      Não use o navegador contra `/health/live` publicamente — isso não é
      o portão correto de validação.

---

## Etapa 2 — Configuração Básica do Keycloak e Testes Isolados (sem AD)

### Ações
1. Ler a senha em `secrets/kc_admin_password.txt` e logar em
   `https://auth.prefeitura.gov.br/admin` como `kc_admin`.
2. Criar o realm `prefeitura` (o `master` fica isolado, só para manutenção).
3. No realm `prefeitura`, criar os grupos `TI_ADMIN` e `SERVIDOR_GERAL`, e um
   usuário local de teste (`teste.ti`) com senha temporária.
4. Criar o client `test-oidc`, Access Type `Confidential`.

### Portão de Validação
- [ ] **Realm master intacto**: nenhum client ou usuário de aplicação foi
      criado no `master` — uso exclusivo administrativo.
- [ ] **Emissão de JWT**:
      ```bash
      curl -d "client_id=test-oidc" \
           -d "client_secret=<SECRET_GERADO>" \
           --data-urlencode "username=teste.ti" \
           --data-urlencode "password=<SENHA>" \
           -d "grant_type=password" \
           https://auth.prefeitura.gov.br/realms/prefeitura/protocol/openid-connect/token
      ```
      Deve retornar um `access_token` JWT válido.
      > **Atenção**: segredos gerados com `openssl rand -base64 32` contêm
      > `+`, `/` e `=`. Use sempre `--data-urlencode` para `username` e
      > `password` no curl — com `-d` puro o `+` vira espaço e a autenticação
      > falha com `invalid_grant` mesmo com a senha certa (validado durante
      > o teste local desta stack).
- [ ] **Auditoria do token**: decodificar em jwt.io e confirmar que
      `iss` = `https://auth.prefeitura.gov.br/realms/prefeitura`.

---

## Etapa 3 — Federação de Identidades com o Active Directory (LDAPS)

> **Caminho recomendado**: `./deploy.sh --configure-ldap` (ou
> `./scripts/configure_ldap.sh` com a stack já no ar) automatiza as ações
> 2 e 3 abaixo via `kcadm.sh` — ver seção "Federação LDAP/AD automatizada"
> no topo deste documento. A ação 1 (copiar a CA) e o portão de validação
> continuam manuais.

### Ações
1. Copiar a CA raiz do AD para `./certs/ad-ca.pem` e reiniciar o Keycloak
   para recarregar o truststore:
   ```bash
   docker compose restart keycloak
   ```
2. Rodar `./scripts/configure_ldap.sh` (recomendado) **ou**, manualmente,
   Admin Console → realm `prefeitura` → **User Federation → Add LDAP**:
   - Connection URL: `ldaps://dc01.prefeitura.local:636`
   - Bind DN: `CN=svc-keycloak,OU=ServiceAccounts,DC=prefeitura,DC=local`
   - Edit Mode: `READ_ONLY`
3. Se feito manualmente, adicionar o mapper `group-ldap-mapper` apontando
   para `OU=Grupos,DC=prefeitura,DC=local` (o script já faz isso).

### Portão de Validação
- [ ] **Test Connection**: sucesso, sem erro de PKIX/certificado.
- [ ] **Test Authentication**: credenciais da conta de bind validadas.
- [ ] **Synchronize all users**: servidores públicos aparecem na aba `Users`.
- [ ] **Login real**: autenticar com a conta de rede de um servidor da
      equipe — a senha é validada diretamente contra o AD, sem ser
      persistida no banco do Keycloak.

---

## Etapa 4 — Integração e Homologação dos Sistemas Piloto

### 1. Intranet Django (OIDC)
- Client `intranet-django` no Keycloak, callback
  `https://intranet.prefeitura.gov.br/oidc/callback/`.
- Biblioteca `mozilla-django-oidc`, configurada em `settings.py`.

### 2. GLPI (OIDC)
- Ativar o plugin OAuth2/OIDC no GLPI.
- Client `glpi-chamados`, mapeando grupos do AD (`TI_SUPORTE` → perfil
  `Technician`).

### 3. Zabbix (SAML 2.0 — **não OIDC**)
> **Correção importante**: o Zabbix **não tem suporte nativo a OpenID
> Connect** (apenas SAML 2.0 nativo, confirmado na documentação oficial).
> Usar OIDC exigiria um proxy Apache adicional com `mod_auth_openidc`, o que
> foi descartado por adicionar complexidade desnecessária.
- Criar um client **SAML** no Keycloak (`zabbix-saml`).
- No Zabbix: **Administração → Autenticação → SAML** (não existe opção
  "OpenID Connect" no menu — se não aparecer SAML, a versão do Zabbix
  precisa de upgrade, mínimo recomendado 6.0+).
- IdP metadata do Keycloak:
  `https://auth.prefeitura.gov.br/realms/prefeitura/protocol/saml/descriptor`
- Habilitar provisionamento Just-In-Time (JIT).

### Portão de Validação
- [ ] **SSO real**: logar na Intranet Django, abrir nova aba e acessar o
      GLPI — deve logar automaticamente, sem pedir senha.
- [ ] **RBAC**: usuário comum do AD entra no GLPI como `Requester`; um
      técnico (grupo `TI_SUPORTE`) entra como `Technician`.
- [ ] **SLO (logout único)**: clicar em "Sair" na Intranet e, ao atualizar
      GLPI e Zabbix, o usuário deve estar deslogado de todas as sessões.

---

## Etapa 5 — Go-Live, Operação e Monitoramento Contínuo

### Ações
1. **Brute Force Detection**: `Realm Settings → Security Defenses → Brute
   Force Detection` — ativar.
2. **MFA obrigatório para TI/Direção**: regra de `Conditional OTP` (TOTP)
   para contas dos grupos administrativos.
3. **Backup diário automatizado**: agendar `scripts/backup.sh` via cron,
   ex.:
   ```bash
   0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
   ```
   (o script já cuida de compressão, checagem de erro e retenção — ver
   `scripts/backup.sh`).

### Portão de Validação
- [ ] **Drill de restauração**: rodar `scripts/restore_test.sh` (restaura o
      backup mais recente em um container Postgres descartável e isolado,
      valida que as tabelas foram restauradas) — deve terminar com `PASS`.
- [ ] **Rotação de logs**: confirmar que os três contêineres estão com
      `max-size: 10m` / `max-file: 3` aplicados:
      ```bash
      docker inspect keycloak_server --format='{{json .HostConfig.LogConfig}}'
      ```
- [ ] **Porta de métricas (9000)**: acessível **apenas internamente** (rede
      Docker), nunca publicada no host nem proxiada publicamente pelo
      Nginx. Prometheus/Zabbix devem coletar a partir de dentro da mesma
      rede Docker ou via um agente rodando na própria VM.

---

## Verificação end-to-end (antes do go-live real em produção)

1. `docker compose config` — valida a sintaxe do compose.
2. `docker compose up -d --build` em ambiente de homologação — todos os
   healthchecks `healthy`.
3. Bateria de curl da Etapa 2 (emissão de JWT), decodificação em jwt.io.
4. Testar LDAPS (Etapa 3) contra um DC de homologação, se disponível, antes
   do DC de produção.
5. Simular login único Django → GLPI → Zabbix (SAML) e logout único.
6. Rodar `scripts/backup.sh` manualmente e depois `scripts/restore_test.sh`
   para validar o ciclo completo de backup/restore antes do go-live real.
