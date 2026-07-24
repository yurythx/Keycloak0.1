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
CN=svc-keycloak,OU=ServiceAccounts,DC=prefeitura,DC=local
```
Com permissão **somente leitura** (bind/consulta) — sem privilégios
administrativos no domínio. Essa conta é usada na
[Etapa 3](03-federacao-ad.md) para a federação LDAPS.

### 4. Certificados
- **TLS público** para `auth.prefeitura.gov.br`, emitido pela CA
  corporativa da prefeitura (`fullchain.pem` + `privkey.pem`).
- **CA raiz do Active Directory**, exportada em `.pem`, para o truststore
  do Keycloak (necessária na [Etapa 3](03-federacao-ad.md) para LDAPS).

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
