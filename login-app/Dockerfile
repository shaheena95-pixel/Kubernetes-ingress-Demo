# ─────────────────────────────────────────────
#  LOGIN APP — Dockerfile
#  Image: nginx serving static HTML
#  Build:   docker build -t login-app .
#  Run:     docker run -p 8081:80 login-app
# ─────────────────────────────────────────────

FROM nginx:alpine

# Remove default nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy our login page
COPY index.html /usr/share/nginx/html/index.html

# Expose port 80
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
