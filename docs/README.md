# Keycloak SSO da Prefeitura — Documentação

Autenticação única (SSO) da prefeitura via Keycloak, com federação ao
Active Directory (LDAPS) e integração com Intranet (Django), GLPI e
Zabbix. Stack em Docker Compose (Postgres + Keycloak + Nginx, com
Portainer opcional), build e publicação de imagem via CI/CD.

## Regra de ouro

Nenhuma etapa avança sem que o **portão de validação** da etapa anterior
tenha passado. Se um portão falhar, pare, corrija a causa raiz e repita a
validação — não pule etapas.

## Arquitetura resumida

```
                      Internet / rede da prefeitura
                                │
                          (só 80/443)
                                │
                      ┌─────────────────┐
                      │  Nginx (proxy)  │  ← único ponto de entrada externo
                      │  TLS obrigatório │
                      └────────┬────────┘
                               │ rede "frontend"
                      ┌────────┴────────┐
                      │    Keycloak     │──── LDAPS ──→ Active Directory
                      │  (sem porta      │
                      │   publicada)     │
                      └────────┬────────┘
                               │ rede "backend" (internal: true,
                               │  sem rota de saída para a internet)
                      ┌────────┴────────┐
                      │    Postgres     │  ← nunca exposto, nem para o host
                      └─────────────────┘

  Portainer (opcional) — bind 127.0.0.1:9443, só via SSH tunnel/VPN
```

## Como usar esta documentação

Se é a primeira implantação, siga a ordem abaixo — cada etapa assume que a
anterior já passou no portão de validação. Se já está tudo no ar e você
só precisa operar o dia a dia, vá direto para
[Referência de Scripts](scripts-referencia.md).

## Índice

| Etapa | Documento | O que cobre |
|---|---|---|
| 0 | [Pré-requisitos e Governança](00-pre-requisitos.md) | VM, firewall, conta de serviço do AD, certificados, janela de manutenção |
| 1 | [Provisionamento e Subida da Stack](01-provisionamento.md) | Docker, `./setup.sh`, `./deploy.sh`, primeiro boot |
| 2 | [Configuração Básica do Keycloak](02-configuracao-keycloak.md) | Realm, grupos, client de teste, emissão de JWT |
| 3 | [Federação com o Active Directory](03-federacao-ad.md) | LDAPS, `configure_ldap.sh`, sincronização de usuários |
| 4 | [Integração dos Sistemas Piloto](04-integracao-sistemas.md) | Django, GLPI, Zabbix (SSO/SLO) |
| 5 | [Go-Live e Operação Contínua](05-golive-operacao.md) | MFA, brute force, backup, `manage.sh`, Portainer, menu automático |
| — | [Referência de Scripts](scripts-referencia.md) | Todos os scripts do repositório, flags e exemplos |
| — | [Tema Visual (logo e cores)](tema-visual.md) | White-label da tela de login com a identidade visual da prefeitura |
| — | [CI/CD e Registry](ci-cd.md) | GitHub Actions, GitLab CI, política de segurança do Trivy |
| — | [Verificação End-to-End](verificacao-final.md) | Checklist final antes do go-live real |

## Checklist rápido de progresso

- [ ] Etapa 0 — Pré-requisitos e Governança
- [ ] Etapa 1 — Provisionamento e Subida da Stack
- [ ] Etapa 2 — Configuração Básica do Keycloak
- [ ] Etapa 3 — Federação com o Active Directory
- [ ] Etapa 4 — Integração dos Sistemas Piloto
- [ ] Etapa 5 — Go-Live e Operação Contínua
- [ ] Verificação End-to-End concluída
