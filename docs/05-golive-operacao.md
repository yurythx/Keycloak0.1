# Etapa 5 — Go-Live, Operação e Monitoramento Contínuo

[← Etapa 4](04-integracao-sistemas.md) · [Índice](README.md) · Próximo: [Verificação End-to-End →](verificacao-final.md)

Última etapa antes do go-live: políticas de segurança do realm, backup
automatizado, e as ferramentas do dia a dia para operar a stack depois
que ela está em produção.

## Ações

### 1. Brute Force Detection
`Realm Settings → Security Defenses → Brute Force Detection` — ativar.

### 2. MFA obrigatório para TI/Direção
Regra de `Conditional OTP` (TOTP) para contas dos grupos administrativos.

### 3. Backup diário automatizado
```bash
crontab -e
```
```
0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
```
O script já cuida de compressão, checagem de erro e retenção. Detalhes em
[Referência de Scripts](scripts-referencia.md#scriptsbackupsh).

## Operação contínua

Depois do go-live, o dia a dia é operado por dois scripts (detalhes
completos em [Referência de Scripts](scripts-referencia.md)):

- **`./manage.sh`** — console interativo estilo TrueNAS: status ao vivo,
  logs, reiniciar/parar/iniciar serviços, atualizar, backup, teste de
  restauração, configurar LDAP, uso de recursos, shell num contêiner.
- **`./scripts/install_console_menu.sh`** (opcional) — faz o `manage.sh`
  aparecer automaticamente em todo login na VM (SSH ou console local),
  igual ao console de setup do TrueNAS. Requer `sudo`.

### Portainer (opcional)
Se habilitado no `.env` (`ENABLE_PORTAINER=true`, perguntado pelo
`setup.sh`), sobe junto com `./deploy.sh`, acessível em
`https://127.0.0.1:9443` via SSH tunnel/VPN. Detalhes e considerações de
segurança em [Referência de Scripts](scripts-referencia.md#portainer).

## Portão de Validação

- [ ] **Drill de restauração**: rodar `scripts/restore_test.sh` (restaura
      o backup mais recente em um contêiner Postgres descartável e
      isolado, valida que as tabelas foram restauradas) — deve terminar
      com `PASS`.
- [ ] **Rotação de logs**: confirmar que os contêineres estão com
      `max-size: 10m` / `max-file: 3` aplicados:
      ```bash
      docker inspect keycloak_server --format='{{json .HostConfig.LogConfig}}'
      ```
- [ ] **Porta de métricas (9000)**: acessível **apenas internamente**
      (rede Docker), nunca publicada no host nem proxiada publicamente
      pelo Nginx. Prometheus/Zabbix devem coletar a partir de dentro da
      mesma rede Docker ou via um agente rodando na própria VM.

---
Próximo: **[Verificação End-to-End →](verificacao-final.md)**
