#Use official Playwright image with browsers already installed
FROM mcr.microsoft.com/playwright:v1.30.0-focal

#Set working directory
WORKDIR /app

#Copy package.json and package-lock.json to install dependencies
COPY package.json package-lock.json ./

#Install dependencies
RUN npm install

#Copy the rest of the application code
COPY . .

#Ensure Report Folders exist
RUN mkidir -p allure-results allure-report test-results playwright-report

#Set the command to run your tests (adjust as needed)
CMD ["npm", "test"]