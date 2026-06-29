# Managed by server-manager — do not edit by hand.
# Site: {{DOMAIN}}  ({{FRAMEWORK}} -> reverse proxy)
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    client_max_body_size 64M;

    location / {
        proxy_pass http://{{UPSTREAM}};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120;
        proxy_buffering off;
    }

    access_log /var/log/nginx/{{DOMAIN}}.access.log;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;
}
