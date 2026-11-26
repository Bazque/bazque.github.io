#!/usr/bin/env bash
# Одноразовая настройка сервера Timeweb для сайта «Тут твой аромат».
# Запуск (под root):
#   curl -fsSL https://raw.githubusercontent.com/Bazque/bazque.github.io/main/deploy/setup-server.sh | bash -s -- ДОМЕН
# ДОМЕН можно не указывать: тогда сайт откроется по IP без https.
# Скрипт можно запускать повторно (например, когда появится домен), он ничего не ломает.
# Бота и другие сайты на сервере скрипт не трогает.
set -euo pipefail

DOMAIN="${1:-}"
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN#www.}"
DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z')"
SITE_DIR=/var/www/tut-tvoy-aromat
ACME_DIR=/var/www/letsencrypt
DEPLOY_USER=sitedeploy
CONF=/etc/nginx/sites-available/tut-tvoy-aromat.conf
LINK=/etc/nginx/sites-enabled/tut-tvoy-aromat.conf

say()  { printf '\n\033[1;32m%s\033[0m\n' "$*"; }
stop() { printf '\n\033[1;31mСТОП: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || stop "запусти скрипт под root (или через sudo)."
command -v apt-get >/dev/null || stop "скрипт рассчитан на Ubuntu или Debian. Напиши в чат, какая система на сервере."

# 1. Кто уже занимает порты 80 и 443 (например, бот)
busy="$(ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null || true)"
if [ -n "$busy" ] && ! echo "$busy" | grep -q nginx; then
  echo "$busy"
  stop "порты 80/443 уже заняты другой программой (возможно, ботом). Ничего не менял. Скопируй строки выше в чат."
fi

NGINX_WAS_THERE=yes
if ! command -v nginx >/dev/null; then
  NGINX_WAS_THERE=no
  say "Ставлю nginx…"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx rsync >/dev/null
  rm -f /etc/nginx/sites-enabled/default
else
  command -v rsync >/dev/null || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null; }
fi
[ -d /etc/nginx/sites-enabled ] || stop "nginx настроен необычно (нет папки sites-enabled). Ничего не менял, напиши в чат."

if [ -z "$DOMAIN" ] && [ "$NGINX_WAS_THERE" = yes ]; then
  # стандартная заглушка nginx «Welcome to nginx» ничего не обслуживает, её можно выключить
  if [ -e /etc/nginx/sites-enabled/default ] && ! grep -Eq '^[^#]*(proxy_pass|fastcgi_pass|uwsgi_pass|grpc_pass)' /etc/nginx/sites-enabled/default; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  others="$(ls /etc/nginx/sites-enabled | grep -v '^tut-tvoy-aromat.conf$' || true)"
  if [ -n "$others" ]; then
    stop "на сервере nginx уже обслуживает другие сайты ($others). Чтобы их не задеть, нужен домен. Запусти скрипт ещё раз с доменом."
  fi
fi

# 2. Папки и отдельный пользователь, у которого есть доступ только к папке сайта
say "Готовлю папку сайта и пользователя для автообновления…"
id "$DEPLOY_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$DEPLOY_USER"
passwd -l "$DEPLOY_USER" >/dev/null 2>&1 || true
mkdir -p "$SITE_DIR" "$ACME_DIR"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$SITE_DIR"
chmod 755 "$SITE_DIR" "$ACME_DIR"
if [ ! -e "$SITE_DIR/index.html" ]; then
  echo '<!doctype html><meta charset="utf-8"><title>Тут твой аромат</title><p style="font:20px sans-serif;text-align:center;margin-top:40vh">Сервер готов, сайт скоро появится.</p>' > "$SITE_DIR/index.html"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$SITE_DIR/index.html"
fi

# 3. Настройки nginx
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
write_conf() {
  local names listen_extra=""
  if [ -n "$DOMAIN" ]; then names="$DOMAIN www.$DOMAIN"; else names="_"; listen_extra=" default_server"; fi
  {
    cat <<CONF
# Сайт «Тут твой аромат». Файл создан deploy/setup-server.sh, при повторном запуске перезаписывается.
server {
    listen 80$listen_extra;
    listen [::]:80$listen_extra;
    server_name $names;

    location ^~ /.well-known/acme-challenge/ { root $ACME_DIR; }
CONF
    if [ -n "$DOMAIN" ] && [ -f "$CERT" ]; then
      echo "    location / { return 301 https://$DOMAIN\$request_uri; }"
      echo "}"
      cat <<CONF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name www.$DOMAIN;
    ssl_certificate     $CERT;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate     $CERT;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;
CONF
    fi
    cat <<CONF
    root $SITE_DIR;
    index index.html;
    charset utf-8;
    absolute_redirect off;
    error_page 404 /404.html;

    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/json;

    location / { try_files \$uri \$uri/ =404; }
    location ~* \.(jpg|jpeg|png|webp|gif|svg|woff2|ico)$ { expires 7d; try_files \$uri =404; }
    location ~* \.html$ { add_header Cache-Control "no-cache"; try_files \$uri =404; }
    location ~ /\. { deny all; }
}
CONF
  } > "$CONF"
  # если на сервере нет IPv6, убираем строки для него
  [ -f /proc/net/if_inet6 ] || sed -i '/listen \[::\]/d' "$CONF"
  ln -sf "$CONF" "$LINK"
  # старые версии nginx не знают «http2 on;»
  if ! nginx -t >/dev/null 2>&1 && grep -q 'http2 on;' "$CONF"; then
    sed -i -e '/http2 on;/d' -e 's/listen 443 ssl;/listen 443 ssl http2;/; s/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' "$CONF"
  fi
  if ! nginx -t 2>/tmp/nginx-check.txt; then
    rm -f "$LINK"
    cat /tmp/nginx-check.txt
    stop "nginx не принял настройки. Я их убрал, остальное работает как раньше. Скопируй текст выше в чат."
  fi
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx
}
say "Настраиваю nginx…"
write_conf

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

# 4. Сертификат https (только с доменом)
MYIP="$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
if [ -n "$DOMAIN" ] && [ ! -f "$CERT" ]; then
  DNSIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
  if [ "$DNSIP" != "$MYIP" ]; then
    say "Домен $DOMAIN пока ведёт на «${DNSIP:-никуда}», а сервер это $MYIP."
    echo "Привяжи домен к серверу в панели Timeweb, подожди 15–30 минут и запусти эту же команду ещё раз. Сайт по http уже работает."
  else
    say "Получаю бесплатный сертификат https…"
    command -v certbot >/dev/null || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/dev/null; }
    WWW=""
    [ "$(getent ahostsv4 "www.$DOMAIN" | awk 'NR==1{print $1}')" = "$MYIP" ] && WWW="-d www.$DOMAIN"
    if certbot certonly --webroot -w "$ACME_DIR" -d "$DOMAIN" $WWW --non-interactive --agree-tos --register-unsafely-without-email; then
      mkdir -p /etc/letsencrypt/renewal-hooks/deploy
      printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
      chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
      write_conf
    else
      echo "Сертификат пока не выдали. Сайт работает по http. Скопируй текст выше в чат."
    fi
  fi
elif [ -n "$DOMAIN" ]; then
  write_conf
fi

# 5. Ключ для GitHub (создаётся один раз)
KEYDIR=/root/.tut-tvoy-aromat-deploy
if [ ! -f "$KEYDIR/key.pub" ]; then
  mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  ssh-keygen -q -t ed25519 -N "" -C "github-deploy-tut-tvoy-aromat" -f "$KEYDIR/key"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  echo "restrict $(cat "$KEYDIR/key.pub")" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
  NEWKEY=yes
else
  NEWKEY=no
fi

SSHPORT="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"; SSHPORT="${SSHPORT:-22}"

say "ГОТОВО. Сервер настроен."
if [ -n "$DOMAIN" ] && [ -f "$CERT" ]; then echo "Адрес сайта: https://$DOMAIN"; elif [ -n "$DOMAIN" ]; then echo "Адрес сайта: http://$DOMAIN (https появится после повторного запуска)"; else echo "Адрес сайта: http://$MYIP"; fi

if [ "$NEWKEY" = yes ]; then
  cat <<TXT

Теперь добавь в GitHub четыре секрета (Settings → Secrets and variables → Actions → New repository secret).
Копируй значения целиком, вместе со строками BEGIN и END. Никому их не пересылай.

──────── SERVER_HOST ────────
$MYIP
──────── SERVER_PORT ────────
$SSHPORT
──────── SERVER_HOST_KEY ────────
$(cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')
──────── SERVER_SSH_KEY (всё, что ниже, до конца рамки) ────────
$(cat "$KEYDIR/key")
─────────────────────────────────
TXT
  rm -f "$KEYDIR/key"
  echo "Закрытый ключ показан один раз и удалён с сервера. Если не успела скопировать, запусти:  rm -rf $KEYDIR  и затем эту команду ещё раз."
else
  echo "Ключ для GitHub уже создавался раньше, секреты менять не нужно."
fi
