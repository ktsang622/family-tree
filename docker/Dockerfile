# Use official Node.js base image
FROM node:20

# Set working directory
WORKDIR /app

# Copy package manifests and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the application code
COPY . .

# Build the Next.js app
RUN npm run build

# Expose the port
EXPOSE 3888

# Start Next.js in production mode
CMD ["npm", "start", "--", "-p", "3888"]
