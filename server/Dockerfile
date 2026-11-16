FROM node:22-alpine
WORKDIR /app

# Dependencies
COPY package*.json ./
RUN npm ci --omit=dev

# Source and bundled game data
COPY src/ ./src/
COPY public/ ./public/
COPY game_data/ ./game_data/

EXPOSE 8080
ENV PORT=8080
ENV HOST=0.0.0.0

CMD ["node", "src/index.js"]
