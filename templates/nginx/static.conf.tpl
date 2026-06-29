# Managed by server-manager — do not edit by hand.
# Site: {{DOMAIN}}  ({{FRAMEWORK}})
server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    root {{ROOT}};
    index index.html;

    # SPA-friendly: fall back to index.html for client-side routing.
    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp|woff2?|ttf|eot)$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public";
    }

    location ~ /\.(?!well-known).* { deny all; }

    access_log /var/log/nginx/{{DOMAIN}}.access.log;
    error_log  /var/log/nginx/{{DOMAIN}}.error.log;
}
