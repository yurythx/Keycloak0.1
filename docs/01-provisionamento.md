# Etapa 1 — Provisionamento de Infraestrutura e Subida da Stack

[← Etapa 0](00-pre-requisitos.md) · [Índice](README.md) · Próxima etapa: [Etapa 2 →](02-configuracao-keycloak.md)

Sobe a stack pela primeira vez: Ubuntu Server, Docker, os scripts de
automação (`setup.sh` + `deploy.sh`), e os quatro portões que provam que a
infraestrutura está correta antes de mexer em qualquer configuração do
Keycloak.

## Ações

### 1. Provisionar a VM
Ubuntu Server 24.04 LTS, sem interface gráfica, sem aaPanel. Instalar
Docker Engine + plugin Docker Compose v2.

### 2. Clonar o repositório e rodar o setup
```bash
git clone <url-do-repositorio> /opt/keycloak-stack
cd /opt/keycloak-stack
./setup.sh
```
`./setup.sh` cria `certs/`, `secrets/`, gera o `.env` de forma interativa
(pergunta domínio, dados do AD, se quer o Portainer, se quer ativar
Let's Encrypt real) e os segredos de 32 caracteres em `secrets/*.txt`. É
idempotente — pode rodar de novo sem sobrescrever nada que já existe.
Detalhes de todas as flags em [Referência de Scripts](scripts-referencia.md#setupsh).

> O bit de execução dos scripts já vem certo do `git clone` (versionado no
> próprio git). Se por algum motivo não estiver executável (ex.: baixou um
> `.zip` em vez de clonar), rode uma vez:
> `chmod +x setup.sh deploy.sh manage.sh scripts/*.sh scripts/lib/*.sh`

### 3. Certificado TLS (opcional copiar algo aqui)
O proxy reverso é o [Traefik](https://traefik.io/) — ele **gerencia o
certificado TLS sozinho**, não há arquivo `.pem` para copiar:
- **Homologação/rede interna** (padrão do `setup.sh`): certificado
  autoassinado gerado automaticamente pelo próprio Traefik.
- **Produção real**: se você respondeu "sim" para Let's Encrypt no
  `setup.sh`, o Traefik emite e renova sozinho via ACME (requer DNS
  público — ver [Etapa 0](00-pre-requisitos.md)).

O único arquivo que ainda é copiado manualmente aqui é:
- `certs/ad-ca.pem` — CA do AD (pode ser feito já aqui ou só na
  [Etapa 3](03-federacao-ad.md), quando for configurar a federação).

### 4. Subir a stack
```bash
./deploy.sh
```
Isso puxa a imagem do Keycloak já publicada pelo CI (ver
[CI/CD e Registry](ci-cd.md)) e sobe tudo — **sem buildar nada na VM**.
Ao final, mostra um painel com o status de cada serviço, URL de acesso e
IP:porta interno.

> Se o pipeline de CI ainda não rodou nenhuma vez (primeiro deploy antes
> do primeiro `push` para `main`), use `./deploy.sh --build` para buildar
> localmente como alternativa temporária.

## Portão de Validação

- [ ] **Status dos contêineres**: `docker compose ps` mostra `keycloak_db`,
      `keycloak_server` e `keycloak_traefik` como `healthy`.
- [ ] **Isolamento de rede**: tentar conectar na porta 5432 a partir de
      outra máquina da rede local — a conexão deve ser **recusada**
      (Postgres não publica porta no host e a rede `backend` é
      `internal: true`).
- [ ] **Handshake TLS**: acessar `https://auth.prefeitura.gov.br/` no
      navegador — tela de login do Keycloak carrega. Em homologação
      (autoassinado) o aviso de "conexão não é segura" é esperado; em
      produção com Let's Encrypt ativado, deve carregar sem avisos.
- [ ] **Liveness/readiness**: `/health/live` e `/health/ready` ficam na
      *management port* (9000) do Keycloak por padrão — **não** na porta
      pública 8080/443, e essa porta **não é exposta** pelo Traefik (evita
      vazar `/metrics` publicamente). Valide a saúde real assim, não pelo
      navegador:
      ```bash
      docker compose ps          # coluna STATUS deve mostrar "healthy"
      docker inspect --format='{{json .State.Health}}' keycloak_server
      ```

---
Próxima etapa: **[Etapa 2 — Configuração Básica do Keycloak →](02-configuracao-keycloak.md)**
