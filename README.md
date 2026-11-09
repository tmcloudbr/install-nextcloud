# install-nextcloud

Script shell que instala o [Nextcloud](https://nextcloud.com) em um servidor Linux com um único comando.

Ele detecta a distribuição e a versão do sistema (via `/etc/os-release`) e escolhe o gerenciador de pacotes e os repositórios corretos para cada caso. Ao final, o Nextcloud fica pronto para uso com **Apache + PHP-FPM + MariaDB + Redis**, com o backend de colaboração em tempo real do Whiteboard e, opcionalmente, o back-end de alto desempenho (HPB) do Talk.

## Instalação rápida

Em um servidor recém-instalado, como root ou com `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash
```

Com domínio e HTTPS (Let's Encrypt):

```bash
curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh \
  | sudo bash -s -- --domain cloud.exemplo.com.br --letsencrypt --email admin@exemplo.com.br
```

Com HTTPS e o back-end de alto desempenho do Talk (chamadas com muitos participantes):

```bash
curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh \
  | sudo bash -s -- --domain cloud.exemplo.com.br --letsencrypt --email admin@exemplo.com.br --talk-hpb
```

Para ver o que seria feito, sem instalar nada:

```bash
curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash -s -- --check
```

> As opções vão depois de `bash -s --`. Sem o `-s --`, o bash não repassa os argumentos para o script.

Também é possível baixar o arquivo e executá-lo localmente:

```bash
curl -fsSLO https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh
less install.sh            # revise antes de executar
sudo bash install.sh --domain cloud.exemplo.com.br
```

## Sistemas suportados

| Distribuição | Versões | Pacotes | Origem do PHP |
|---|---|---|---|
| Debian | 12, 13 | apt | oficial; [packages.sury.org](https://packages.sury.org/php/) quando o oficial está fora da faixa exigida |
| Ubuntu | 22.04, 24.04, 26.04 | apt | oficial; PPA `ondrej/php` quando o oficial está fora da faixa exigida |
| RHEL, Rocky Linux, AlmaLinux, CentOS Stream, Oracle Linux | 8, 9 | dnf | repositório Remi (módulo `php:remi-X.Y`) + EPEL/CRB |
| RHEL, Rocky Linux, AlmaLinux, CentOS Stream, Oracle Linux | 10 | dnf | oficial + Remi/EPEL para extensões PECL |
| Fedora | 41 ou superior | dnf | oficial |

Arquiteturas: `x86_64` e `aarch64`. É necessário **systemd**.

Testado em Debian 12 e 13, Ubuntu 22.04 e 24.04, Rocky Linux 9, AlmaLinux 10 e Fedora 42, sempre com o Nextcloud 35.0.2.

Derivados (Linux Mint, Pop!_OS etc.) são reconhecidos pelo `ID_LIKE`, mas só rodam com `--force`.

### Como a versão do PHP é escolhida

Cada versão do Nextcloud aceita uma faixa de versões do PHP (o Nextcloud 35, por exemplo, aceita 8.3–8.5). O script:

1. descobre a versão concreta do Nextcloud que será instalada (a mais recente, ou a informada em `--version`);
2. lê a faixa de PHP exigida no `lib/versioncheck.php` dessa versão;
3. usa o PHP do sistema se ele estiver dentro da faixa; se não estiver, adiciona o repositório externo da tabela acima e instala o PHP 8.4 (ou a maior versão aceita);
4. depois do download, confere de novo a faixa no código baixado, antes de instalar.

## Requisitos

- Servidor **limpo**, sem outro servidor web ou banco de dados já configurado
- Acesso root (`sudo`)
- Acesso à internet: download.nextcloud.com, GitHub, `ghcr.io` (imagens dos containers) e os repositórios da distribuição
- Pelo menos 2 GB de RAM e 2 GB livres em disco, mais o espaço para os arquivos dos usuários
- Para `--letsencrypt`: um domínio cujo DNS aponte para o servidor, com as portas 80 e 443 abertas
- Para `--talk-hpb`: HTTPS (`--letsencrypt`) e a porta do TURN (padrão 3478, **TCP e UDP**) liberada até o servidor, inclusive em firewalls externos/grupos de segurança da nuvem

## Opções

| Opção | Variável de ambiente | Padrão | Descrição |
|---|---|---|---|
| `--domain DOMINIO` | `NC_DOMAIN` | IP do servidor | Domínio/hostname de acesso |
| `--admin-user USUARIO` | `NC_ADMIN_USER` | `admin` | Usuário administrador |
| `--admin-pass SENHA` | `NC_ADMIN_PASS` | aleatória | Senha do administrador |
| `--db-name NOME` | `NC_DB_NAME` | `nextcloud` | Nome do banco de dados |
| `--db-user USUARIO` | `NC_DB_USER` | `nextcloud` | Usuário do banco de dados |
| `--db-pass SENHA` | `NC_DB_PASS` | aleatória | Senha do banco (letras, números e `. _ @ % + = -`) |
| `--install-dir DIR` | `NC_INSTALL_DIR` | `/var/www/nextcloud` | Diretório da aplicação |
| `--data-dir DIR` | `NC_DATA_DIR` | `/var/www/nextcloud-data` | Diretório dos arquivos dos usuários |
| `--version X.Y.Z` | `NC_VERSION` | `latest` | Versão do Nextcloud |
| `--php-version X.Y` | `NC_PHP_VERSION` | automático | Força uma versão do PHP |
| `--timezone TZ` | `NC_TIMEZONE` | `America/Sao_Paulo` | Fuso horário |
| `--phone-region XX` | `NC_PHONE_REGION` | `BR` | Região telefônica (ISO 3166-1) |
| `--letsencrypt` | `NC_LETSENCRYPT=yes` | desativado | Emite certificado HTTPS (requer `--domain` e `--email`) |
| `--email EMAIL` | `NC_EMAIL` | — | E-mail para o Let's Encrypt |
| `--talk-hpb` | `NC_TALK_HPB=yes` | desativado | Instala o back-end de alto desempenho do Talk (requer `--letsencrypt`) |
| `--talk-port PORTA` | `NC_TALK_PORT` | `3478` | Porta TCP/UDP do TURN do Talk |
| `--check` | `NC_CHECK_ONLY=yes` | — | Só detecta o sistema e mostra o plano |
| `--force` | `NC_FORCE=yes` | — | Continua em distribuição ou versão não suportada |
| `-h`, `--help` | — | — | Mostra a ajuda |

Se usar variáveis de ambiente, passe-as **depois** do `sudo`, porque o `sudo` descarta as variáveis do usuário:

```bash
curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh \
  | sudo NC_DOMAIN=cloud.exemplo.com.br NC_ADMIN_USER=tmcloud bash
```

## O que o script faz

1. Detecta a distribuição e a versão e verifica arquitetura, memória, disco, conectividade e se já existe uma instalação no destino.
2. Instala Apache, PHP-FPM com as extensões exigidas e recomendadas (APCu, Redis, Imagick, OPcache…), MariaDB e Redis (ou Valkey), adicionando os repositórios externos só quando necessários.
3. Configura:
   - **PHP**: `memory_limit` 512M, uploads de até 16 GB, OPcache e o pool do PHP-FPM;
   - **MariaDB**: `READ-COMMITTED`, `utf8mb4`, `innodb_log_file_size` 256M, log de consultas lentas (> 2 s), banco e usuário dedicados;
   - **Apache**: `mpm_event` + `proxy_fcgi`, virtual host em `*:80`, cabeçalho HSTS e proxy WebSocket para `/whiteboard/` (e `/standalone-signaling/` com `--talk-hpb`).
4. Baixa o Nextcloud, confere o **SHA-256** e instala com `occ maintenance:install`.
5. Aplica as configurações recomendadas: `trusted_domains`, cache local (APCu), cache distribuído e locking (Redis), região telefônica, fuso horário e janela de manutenção.
6. Cria o timer do systemd `nextcloud-cron.timer`, que roda o `cron.php` a cada 5 minutos.
7. Ajusta SELinux (RHEL/Fedora) e libera HTTP/HTTPS no `firewalld` ou `ufw`, se estiverem ativos.
8. Com `--letsencrypt`, emite o certificado com o `certbot` e redireciona HTTP para HTTPS.
9. Sobe o backend do **Whiteboard** (container `ghcr.io/nextcloud-releases/whiteboard`, via Podman + systemd, ouvindo só em `127.0.0.1:3002`) e configura no app a URL `/whiteboard` e o segredo JWT. Isso resolve o aviso *"O URL do servidor WebSocket não está configurado"*.
10. Com `--talk-hpb`, sobe o container `ghcr.io/nextcloud-releases/aio-talk` (signaling + Janus + NATS + TURN), com o signaling em `127.0.0.1:8081` e o TURN na porta 3478 TCP/UDP. Também libera essa porta no firewall local e registra signaling, STUN e TURN no Talk (`occ talk:*`). Isso resolve o aviso *"Nenhum back-end de alto desempenho configurado"*.

Uma falha no Whiteboard ou no Talk HPB não interrompe a instalação: o script mostra um aviso e o Nextcloud continua funcionando sem o recurso.

Se o download via `curl` for interrompido no meio, nada é executado: todo o código fica dentro de funções, que só são chamadas na última linha do arquivo.

## Depois da instalação

| Arquivo | Conteúdo |
|---|---|
| `/root/nextcloud-credentials.txt` | URL, usuário e senha do admin e credenciais do banco (permissão `600`) |
| `/var/log/nextcloud-install.log` | Log completo da instalação |
| `/etc/nextcloud-services/whiteboard.env` | URL e segredo JWT do backend do Whiteboard (permissão `600`) |
| `/etc/nextcloud-services/talk-hpb.env` | Segredos do signaling e do TURN do Talk (só com `--talk-hpb`) |

Acesse a URL exibida no final e entre com o usuário administrador.

### Configurações opcionais no `config.php`

No fim do `config/config.php`, o script adiciona blocos **comentados** de `trusted_domains` e `trusted_proxies`, com valores de exemplo:

```php
  # Domínios e IPs pelos quais o Nextcloud pode ser acessado
  // 'trusted_domains' =>
  // array (
  //   0 => 'ip-domain',
  //   1 => 'nextcloud.dominio',
  // ),
  #
  # IPs dos proxies reversos à frente do Nextcloud
  // 'trusted_proxies' =>
  // array (
  //   0 => 'ip-proxie',
  // ),
```

Para ativar um bloco:

1. remova o `//` do início de cada linha dele (as linhas com `#` são só descrição);
2. troque os valores de exemplo pelos reais;
3. se ativar `trusted_domains`, apague o `trusted_domains` que já existe mais acima no arquivo, porque o PHP usa a última definição da chave.

Para conferir, rode `occ config:system:get trusted_domains` e `occ config:system:get trusted_proxies`.

> **Atenção:** o Nextcloud reescreve o `config.php` sempre que uma configuração é alterada pelo `occ config:system:set` ou pelo painel. Isso **remove os comentários**. Os valores já ativados (sem `//`) são mantidos.

Comandos úteis:

```bash
# Debian/Ubuntu (usuário www-data)
sudo -u www-data php /var/www/nextcloud/occ status

# RHEL/Fedora (usuário apache)
sudo -u apache php /var/www/nextcloud/occ status

# Tarefas em segundo plano
systemctl list-timers nextcloud-cron.timer

# Backends em container
systemctl status nextcloud-whiteboard nextcloud-talk-hpb
journalctl -u nextcloud-whiteboard -f

# Atualizar as imagens dos containers
podman pull ghcr.io/nextcloud-releases/whiteboard:release && systemctl restart nextcloud-whiteboard
podman pull ghcr.io/nextcloud-releases/aio-talk:latest && systemctl restart nextcloud-talk-hpb
```

### HPB do Talk em servidor separado

Para muitas chamadas simultâneas, a recomendação da Nextcloud é rodar o HPB em um servidor dedicado. Nesse caso, instale sem `--talk-hpb` e registre o HPB externo:

```bash
sudo -u www-data php /var/www/nextcloud/occ talk:signaling:add https://signaling.exemplo.com.br/ SEGREDO --verify
sudo -u www-data php /var/www/nextcloud/occ talk:turn:add turn signaling.exemplo.com.br:3478 udp,tcp --secret=SEGREDO_TURN
```

### HTTPS depois da instalação

Se a instalação foi feita sem `--letsencrypt`, o acesso fica em HTTP. Para ativar o HTTPS depois:

```bash
# Debian/Ubuntu: apt install certbot python3-certbot-apache
# RHEL/Fedora:   dnf install certbot python3-certbot-apache
certbot --apache -d cloud.exemplo.com.br -m admin@exemplo.com.br --agree-tos --redirect

sudo -u www-data php /var/www/nextcloud/occ config:system:set overwriteprotocol --value=https
sudo -u www-data php /var/www/nextcloud/occ config:system:set overwrite.cli.url --value=https://cloud.exemplo.com.br
```

(Em RHEL/Fedora, use `-u apache` no lugar de `-u www-data`.)

## Solução de problemas

- **"Já existe uma instalação do Nextcloud…"**: por segurança, o script nunca sobrescreve `--install-dir` ou `--data-dir` que não estejam vazios.
- **Falha ao baixar metadados do EPEL (RHEL 8/9)**: espelhos regionais do EPEL às vezes ficam dessincronizados por algumas horas. O script tenta uma segunda vez; se continuar falhando, aguarde e execute de novo.
- **Whiteboard ou Talk HPB não subiram**: veja `journalctl -u nextcloud-whiteboard` ou `journalctl -u nextcloud-talk-hpb`. As causas mais comuns são falta de acesso ao `ghcr.io` e, no Talk, a porta do TURN bloqueada em um firewall externo. Se o Let's Encrypt falhar, o HPB do Talk não é instalado.
- **Let's Encrypt falhou**: a instalação continua em HTTP. Confira se o DNS do domínio aponta para o servidor e se a porta 80 está acessível, e rode o `certbot` manualmente (veja acima).
- **Qualquer outra falha**: a mensagem mostra a linha e o comando que falharam. O log completo está em `/var/log/nextcloud-install.log`.

## Testes

O script foi testado em containers Docker com systemd, **sem `--privileged`**:

```bash
docker run -d --name nc-test \
  --cgroupns=private --security-opt writable-cgroups=true \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec \
  <imagem-com-systemd> /sbin/init
```

Containers sem privilégio não conseguem criar namespaces. Por isso, só no ambiente de teste, o sandboxing das units do systemd (`PrivateUsers=`, `ProtectSystem=` etc.) foi desativado com um drop-in em `/etc/systemd/system/service.d/`. Em servidores reais isso não é necessário. Nesse ambiente o Podman não consegue rodar containers aninhados, então o Whiteboard e o Talk HPB terminam só com aviso.
