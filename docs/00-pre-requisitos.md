# Etapa 0 — Pré-requisitos e Governança

[← Índice](README.md) · Próxima etapa: [Etapa 1 — Provisionamento →](01-provisionamento.md)

Antes de tocar em qualquer comando, esta etapa garante que a equipe tem
tudo em mãos para não travar no meio da implantação — dependências
externas (AD, certificados) costumam ser o gargalo real, não a stack em
si.

## Ações

### 1. Dimensionar a VM
Mínimo recomendado: **8 vCPU / 16 GB RAM / 100 GB de disco**. O tuning do
Postgres usa `shared_buffers=1GB` e o Keycloak roda com heap JVM de até
4 GB — some isso ao overhead do SO e a uma margem de crescimento.

### 2. Firewall
Liberar entrada **apenas** nas portas `80` e `443` na VM. Nenhuma outra
porta (5432 do Postgres, 8080 do Keycloak, 9000 de métricas) deve ser
alcançável de fora do host — a stack já garante isso por padrão (ver
[Etapa 1](01-provisionamento.md)), mas o firewall de borda é a segunda
camada de defesa.

### 3. Conta de serviço do Active Directory
Solicitar à equipe do AD a criação de uma conta de serviço, por exemplo:
```
CN=svc-keycloak,OU=ServiceAccounts,DC=rondonopolis,DC=local
```
Com permissão **somente leitura** (bind/consulta) — sem privilégios
administrativos no domínio. Essa conta é usada na
[Etapa 3](03-federacao-ad.md) para a federação LDAPS.

### 4. Certificado TLS público
O proxy reverso é o [Traefik](https://traefik.io/), que gerencia o
certificado TLS — três modos possíveis, escolha o que se aplica:
- **Homologação/rede interna** (padrão): o Traefik serve um certificado
  autoassinado próprio, sem nenhuma configuração — o navegador mostra o
  aviso padrão de "conexão não é segura", esperado nesse modo.
- **Produção real com [Let's Encrypt](https://letsencrypt.org/)**: exige
  **DNS público** resolvendo `sso.rondonopolis.mt.gov.br` para o IP desta VM,
  e as portas 80/443 alcançáveis da internet (o desafio TLS-ALPN do
  Let's Encrypt acontece nelas). O `setup.sh` pergunta se quer ativar
  esse modo — se sim, o Traefik emite e renova o certificado sozinho.
- **Certificado próprio, emitido pela CA interna/corporativa da
  prefeitura** (o caminho mais comum quando o domínio só resolve na rede
  interna, sem DNS público apontando pra fora): não precisa de DNS público
  nem de Let's Encrypt — só copiar `fullchain.pem`/`privkey.pem` em
  `traefik/certs/` e rodar `./setup.sh` de novo. Ver
  [Referência de Scripts](scripts-referencia.md#traefik).

Nos três casos **nenhum arquivo é obrigatório antes do primeiro
deploy** — o padrão (autoassinado) sempre funciona sem configuração
alguma; os outros dois são escolhas explícitas.

Ainda é necessária:
- **CA raiz do Active Directory**, exportada em `.pem`, para o truststore
  do Keycloak (necessária na [Etapa 3](03-federacao-ad.md) para LDAPS) —
  isso é independente do certificado TLS do proxy.

### 5. Janela de manutenção
Aprovada e comunicada às áreas afetadas.

### 6. Procedimento de rollback
Documentado e aprovado antes do go-live, por exemplo:
```bash
./deploy.sh --down
# restaurar snapshot da VM, ou reverter DNS para o sistema de login anterior
```
`./deploy.sh --down` preserva o volume do Postgres por padrão — só use
`--down --purge` se o objetivo explícito for apagar os dados (ver
[Referência de Scripts](scripts-referencia.md#deploysh)).

## Portão de Validação (Go/No-Go)

- [ ] Checklist acima assinado pelo responsável de infraestrutura do AD e
      pelo gestor da janela de manutenção.
- [ ] Certificado TLS da CA da prefeitura e CA raiz do AD já em mãos —
      **não iniciar a Etapa 1 sem eles**.

---
Próxima etapa: **[Etapa 1 — Provisionamento e Subida da Stack →](01-provisionamento.md)**
