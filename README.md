# Zabbix 7.0 LTS - Deploy Automatizado para Proxmox

Dois scripts para provisionar uma VM Debian 13 (Trixie) no Proxmox e instalar
a stack completa do Zabbix 7.0 LTS com PostgreSQL 17 + TimescaleDB + Apache +
agent2. Dimensionado para até 100–150 hosts monitorados.

---

## Estrutura

```
zabbix-proxmox-deploy/
├── proxmox-provision.sh   # Cria a VM no HOST Proxmox (executar no host)
├── zabbix-install.sh      # Instalador in-VM (executado via cloud-init)
└── README.md
```

`zabbix-install.sh` é embutido em base64 no user-data do cloud-init pelo
`proxmox-provision.sh` — não precisa transferir nada manualmente.

---

## Segurança no host Proxmox (e em cluster)

O `proxmox-provision.sh` foi escrito para **nunca tocar no host nem em outras VMs**:

- recusa se o VMID já existe **em qualquer nó do cluster** (verificação via `/cluster/resources`)
- aborta se o cluster estiver **sem quorum** (`pvecm status`) — para não corromper config
- valida que o storage e a bridge existem antes de criar qualquer coisa
- avisa se a memória pedida exceder a folga do nó atual (não fatal)
- snippet de cloud-init por VMID (`/var/lib/vz/snippets/zabbix-<VMID>-userdata.yaml`)
- nada de pacotes/sysctls/firewall no host
- toda a parte pesada (PostgreSQL, schema, tuning) corre **dentro** da VM

A VM em si tem `--onboot 1` (sobe junto com o host) e `--balloon 0` (sem ballooning,
para o PostgreSQL não sofrer com pressão de memória do hypervisor).

### Em cluster com produção

- O script roda no **nó local onde estás logado** — a VM é criada nesse nó.
  Para criar noutro nó, SSH para esse nó primeiro: `ssh root@pve-node2 'cd /opt/zabbix-deploy && bash proxmox-provision.sh ...'`.
- O VMID é único no cluster; o script descobre IDs em uso em todos os nós e
  falha antes de tentar criar. Use `pvesh get /cluster/nextid` para ver o próximo livre.
- Storage local (`local-lvm`, `local-zfs`): isolado por nó — a VM fica presa
  a esse nó (sem migração ao vivo). Use storage partilhado (Ceph, NFS) se
  precisar de HA/migração.
- O script **não mexe em corosync, /etc/pve, firewall do cluster, HA groups,
  ou backup jobs**. É 100% scope-do-novo-VMID.

---

## Uso rápido

### Cenário 1 — Criar VM nova com defaults (DHCP)

No host Proxmox, como root:

```bash
cd /opt/zabbix-deploy
bash proxmox-provision.sh
```

Defaults: VMID auto (`pvesh get /cluster/nextid`), 8 GB RAM, 4 cores, 100 GB disco, `local-lvm`, `vmbr0`, DHCP.
As senhas da BD são geradas e mostradas no resumo final.

### Cenário 2 — IP estático, VLAN, senhas próprias

```bash
bash proxmox-provision.sh \
  --name zabbix-prod \
  --memory 8192 --cores 4 --disk 100 \
  --vlan 100 \
  --ip 192.0.2.10/24 \
  --gw 192.0.2.1 \
  --sshkey ~/.ssh/id_rsa.pub \
  --db-pass 'senhaBD' \
  --admin-pass 'senhaAdmin'
```

Tudo o que estiver omisso usa o default. Senhas ausentes são geradas.
O VMID é auto-atribuído; passe `--vmid <n>` para fixar um valor específico.

### Mudar o VMID depois

Proxmox não tem "rename VMID". Para trocar:

```bash
# Opção A: backup + restore (limpo, exige downtime)
vzdump 210 --storage local --mode snapshot --compress zstd
qmrestore /var/lib/vz/dump/vzdump-qemu-210-*.vma.zst 215 --storage local-lvm
qm destroy 210

# Opção B: clone (sem downtime, mas duplica disco temporariamente)
qm clone 210 215 --full --name zabbix-prod
qm destroy 210
```

### Cenário 3 — VM já existe, só quero instalar

Copie `zabbix-install.sh` para dentro da VM e execute como root:

```bash
sudo bash zabbix-install.sh
# ou com senhas customizadas:
ZBX_DB_PASS='senhaBD' ZBX_ADMIN_PASS='senhaAdmin' sudo -E bash zabbix-install.sh
```

---

## Variáveis aceites

### `proxmox-provision.sh` (flags ou env)

| Flag         | Env          | Default                        |
|--------------|--------------|--------------------------------|
| `--vmid`     | `VMID`       | _(auto via `/cluster/nextid`)_ |
| `--name`     | `VM_NAME`    | `zabbix-monitoring`            |
| `--memory`   | `VM_MEMORY`  | `8192` (MB)                    |
| `--cores`    | `VM_CORES`   | `4`                            |
| `--disk`     | `VM_DISK_SIZE` | `100` (GB)                   |
| `--storage`  | `VM_STORAGE` | `local-lvm`                    |
| `--bridge`   | `VM_BRIDGE`  | `vmbr0`                        |
| `--vlan`     | `VM_VLAN`    | _(vazio)_                      |
| `--ip`       | `VM_IP`      | `dhcp`                         |
| `--gw`       | `VM_GW`      | _(obrigatório se IP estático)_ |
| `--dns`      | `VM_DNS`     | `8.8.8.8`                      |
| `--sshkey`   | `VM_SSHKEY`  | _(vazio)_                      |
| `--db-pass`  | `ZBX_DB_PASS`| _(gerada aleatoriamente)_      |
| `--admin-pass` | `ZBX_ADMIN_PASS` | _(vazio → mantém 'zabbix' default)_ |

### `zabbix-install.sh` (env)

| Var             | Default                                |
|-----------------|----------------------------------------|
| `ZBX_DB_NAME`   | `zabbix`                               |
| `ZBX_DB_USER`   | `zabbix`                               |
| `ZBX_DB_PASS`   | _(gerada — 20 chars alfanuméricos)_    |
| `ZBX_ADMIN_PASS`| _(vazio → mantém default `zabbix`)_    |
| `ZBX_TIMEZONE`  | `Africa/Luanda`                        |

---

## Requisitos da VM

| Recurso | Mínimo | Recomendado (este script) |
|---------|--------|----------------------------|
| CPU     | 2      | 4 cores                    |
| RAM     | 4 GB   | 8 GB                       |
| Disco   | 40 GB  | 100 GB                     |
| OS      | Debian 13 (Trixie) — outras não testadas |

Para crescer além de 200 hosts, considere subir para 16 GB RAM e ativar
compressão TimescaleDB (vê abaixo).

---

## Formato do disco

O script chama `qm importdisk ... --format qcow2`, mas **o formato real é
decidido pelo backend de storage**:

| Storage              | Formato real | Notas                                |
|----------------------|--------------|--------------------------------------|
| `local` (dir)        | qcow2        | honra a flag                         |
| **`local-lvm`** (default) | **raw**  | LVM-thin ignora qcow2; PVE converte  |
| `local-zfs`          | raw (zvol)   | ZFS, qcow2 ignorado                  |
| Ceph RBD             | raw          | RBD nativo                           |
| NFS / CIFS           | qcow2        | honra a flag                         |

Em `local-lvm` (default) o disco fica **raw** — melhor para a workload do
PostgreSQL (sem penalidade de double-write do qcow2). As flags importantes
no `qm set --scsi0` continuam a aplicar-se: `discard=on` (TRIM passthrough),
`ssd=1` (hint de SSD), `iothread=1` (thread de IO dedicada).

---

## Verificação da imagem cloud (integridade)

Antes de importar, o script verifica:

1. **Assinatura GPG** do ficheiro `SHA512SUMS` contra a chave da **Debian
   Cloud Team** (`DF9B9C49EAA9298432589D76DA87E80D6294BE9B` por defeito).
   Chave é obtida de `keyring.debian.org` (fallback `keys.openpgp.org`).
2. **SHA512** da imagem qcow2 contra a entrada em `SHA512SUMS`.

Falha fechada em qualquer um dos passos — protege contra:
- Corrupção em trânsito (MITM mesmo com HTTPS comprometido)
- Servidor mirror comprometido
- Ficheiro local adulterado entre downloads

Overrides:

```bash
# Se a Debian rotacionar a chave (raro):
DEBIAN_CLOUD_KEYS="newfpr1 newfpr2" bash proxmox-provision.sh ...

# Bypass total (debug / ambiente offline; NÃO usar em produção):
SKIP_IMAGE_VERIFY=1 bash proxmox-provision.sh ...
```

Pré-requisito: `gnupg` instalado no host Proxmox (já vem por defeito em PVE).

---

## Portas

| Porta  | Proto | Serviço                  |
|--------|-------|--------------------------|
| 80     | TCP   | Frontend Zabbix          |
| 10050  | TCP   | Zabbix agent (passivo)   |
| 10051  | TCP   | Zabbix server (trapper)  |
| 5432   | TCP   | PostgreSQL — **só localhost** |

---

## Tuning aplicado por omissão

### PostgreSQL 17 (drop-in em `/etc/postgresql/17/main/conf.d/99-zabbix.conf`)

- `shared_buffers=2GB`, `effective_cache_size=6GB`
- `work_mem=16MB`, `maintenance_work_mem=512MB`
- `max_connections=200`
- `random_page_cost=1.1` (SSD)
- `shared_preload_libraries='timescaledb'`
- WAL: `max_wal_size=4GB`, `checkpoint_completion_target=0.9`

### Zabbix server (`/etc/zabbix/zabbix_server.conf`)

- `StartPollers=20`, `StartPollersUnreachable=5`
- `StartPreprocessors=8`, `StartPingers=4`, `StartHTTPPollers=4`
- `CacheSize=128M`, `ValueCacheSize=128M`
- `HistoryCacheSize=64M`, `TrendCacheSize=32M`
- `Timeout=15`, `LogSlowQueries=3000`

Se ultrapassar 150 hosts e/ou 2000 NVPS, suba `StartPollers` e `HistoryCacheSize`.

---

## Após instalação

O setup wizard **já está saltado** — o script pré-grava `/etc/zabbix/web/zabbix.conf.php`
com as credenciais geradas. Para regenerar (ex: mudaste a senha da BD à mão),
apaga o ficheiro e abre `/zabbix/setup.php`.

1. Acesse `http://<IP-VM>/zabbix/` — cai directo no login
2. Login: `Admin` / `<a senha que escolheu — ou 'zabbix' se omitiu --admin-pass>`
3. Ative o host **"Zabbix server"** (vem desativado por omissão):
   Configuration → Hosts → Zabbix server → Enabled
4. Ative compressão TimescaleDB:
   - **Administration → General → Housekeeping**
   - "Override item history period" + "Override item trend period"
   - "Enable compression"

### + integração com Azure Monitor

O Zabbix 7.0 vem com templates oficiais para Azure (sem precisar instalar nada extra):

- **Azure by HTTP** (subscriptions, gestão geral)
- **Azure VM by HTTP**, **Azure SQL DB by HTTP**, **Azure MySQL by HTTP**, etc.

Para usar:

1. No Azure: cria-se um App Registration (service principal) com permissão
   `Reader` na subscription.
2. No Zabbix: **Configuration → Hosts → Create host** com o template
   `Azure by HTTP`, e nas macros do host preenche `{$AZURE.TENANT.ID}`,
   `{$AZURE.APP.ID}`, `{$AZURE.SECRET.KEY}`, `{$AZURE.SUBSCRIPTION.ID}`.

---

## Backup (configurar preferencialmente de imediato após o deploy)

O script **não cria** jobs de backup deliberadamente — política de backup
vive em `/etc/pve/jobs.cfg` (cluster-wide), e fragmentar essa config a partir
de scripts de deploy é má prática.

**Faça você assim que o script terminar.** Via GUI:
**Datacenter → Backup → Add** → selecione o VMID, agendamento, storage.

Via CLI (substitua `pbs01` pelo nome do seu storage de backup):

```bash
pvesh create /cluster/backup \
  --vmid 210 \
  --storage pbs01 \
  --schedule "02:30" \
  --mode snapshot \
  --compress zstd \
  --mailnotification failure \
  --enabled 1
```

### Para PITR (Point-in-Time Recovery) do PostgreSQL

Snapshots de VM são **crash-consistent** — se o PG estiver no meio de um
fsync, o restore é como se a VM tivesse perdido energia. PG aguenta (WAL
recovery), mas perdes os updates desde o último checkpoint.

Para PITR a sério, configure dentro da VM:
- `archive_mode = on` + `archive_command` para enviar WAL a um destino
- `pg_basebackup` semanal complementar ao snapshot da VM
- Ferramentas tipo **pgBackRest** ou **Barman** se a deployment crescer

---

## Logs

```bash
# Instalação
tail -f /var/log/zabbix-install.log

# Server / agent / Apache
journalctl -u zabbix-server -f
journalctl -u zabbix-agent2 -f
journalctl -u apache2 -f

# PostgreSQL
tail -f /var/log/postgresql/postgresql-17-main.log
```

---

## Reinstalar / iterar

O `zabbix-install.sh` é idempotente nas partes seguras:

- repo Zabbix e Timescale: `dpkg -i` é reaplicado sem efeitos colaterais
- `create_zabbix_db`: usa `IF NOT EXISTS` / `ALTER ROLE`
- `import_zabbix_schema`: detecta tabela `users` e pula se já carregado
- `tune_postgres`: drop-in dedicado, não toca no `postgresql.conf` principal

Para começar do zero, o caminho mais limpo é destruir a VM e relançar:

```bash
qm stop  210 && qm destroy 210
bash proxmox-provision.sh --vmid 210
```

---

## Múltiplos nós

```bash
NODES=("pve-node1" "pve-node2" "pve-node3")
VMID=210
for NODE in "${NODES[@]}"; do
  scp proxmox-provision.sh zabbix-install.sh root@${NODE}:/opt/zabbix-deploy/
  ssh root@${NODE} "bash /opt/zabbix-deploy/proxmox-provision.sh --vmid ${VMID} --name zabbix-${NODE}"
  ((VMID++))
done
```
