Teste de fork PR...

# Infraestrutura – Hackathon

Este repositório contém a **infraestrutura como código (IaC)** do projeto do Hackathon desenvolvido pelo grupo **The Code Crafters**.

A infraestrutura foi projetada para suportar uma **arquitetura de microserviços baseada em containers e orientada a eventos**, com foco em escalabilidade, resiliência, controle de custos e separação clara de responsabilidades entre os serviços.

---

## 🎯 Objetivos da Arquitetura

- Suportar **múltiplos processamentos de vídeo em paralelo**
- Evitar perda de requisições em picos de carga
- Garantir **isolamento e rastreabilidade por usuário**
- Habilitar processamento assíncrono
- Manter a infraestrutura **simples, explicável e com custo controlado** (contexto de hackathon)

---

## 🧩 Visão Geral da Arquitetura

A solução é composta por três microserviços principais:

- **Serviço de Upload** – recebe as requisições de upload e registra os jobs de processamento
- **Serviço de Download** – fornece acesso seguro aos arquivos processados
- **Processador (Worker)** – consome jobs de forma assíncrona e executa o processamento dos vídeos

A autenticação e autorização são realizadas pelo **Amazon Cognito**, enquanto a orquestração dos jobs utiliza o **Amazon SQS**.

---

## 🏗️ Diagrama Final da Arquitetura

> **Visão visual da arquitetura (alto nível)**  
> A imagem abaixo representa a arquitetura implementada neste repositório, incluindo ALB, ECS Fargate, SQS, RDS, S3 e Cognito.
>
> ![Arquitetura Hackathon – The Code Crafters](images/architecture.png)
>
> 📌 **Observação:** salve a imagem da arquitetura no caminho `images/architecture.png` dentro deste repositório para que ela seja renderizada corretamente no GitHub.

```text
┌────────────┐
│  Cliente   │
│ (Browser / │
│  API Tool) │
└─────┬──────┘
      │  JWT (Cognito)
      v
┌───────────────┐
│      ALB      │
│  (HTTP :80)   │
└─────┬─────────┘
      │
      ├───────────────┐ 
      │               │
      v               v
┌───────────────┐   ┌─────────────────┐
│ API Upload    │   │ API Download    │
│ (ECS Fargate) │   │ (ECS Fargate)   │
│ :8000         │   │ :8000           │
└─────┬─────────┘   └─────────┬───────┘
      │                         │
      │ Metadados do job        │ Validação de posse
      v                         v
┌────────────────────────────────────┐
│         Amazon RDS (Postgres)       │
│   Jobs, status e dono do job        │
└───────────────┬────────────────────┘
                │
                │ Mensagem do job
                v
        ┌─────────────────┐
        │   Amazon SQS    │
        │  (Fila de Jobs)│
        └────────┬────────┘
                 │
                 v
        ┌─────────────────┐
        │ Processador     │
        │ (ECS Fargate)   │
        │ Sem inbound     │
        └───────┬─────────┘
                │
        ┌───────┴─────────┐
        │   Amazon S3     │
        │ input/ output/ │
        └────────────────┘

Autenticação:
- Amazon Cognito User Pool (JWT)

Artefatos:
- Amazon ECR (imagens de container)
```

---

## 🔐 Autenticação e Controle de Usuários

- Os usuários se autenticam via **Amazon Cognito User Pool**
- As APIs validam **tokens JWT** diretamente (sem API Gateway)
- A claim `sub` do token é utilizada como `user_id`
- Cada job é estritamente associado a um único usuário

### 🔑 Tokens e Identidade (Amazon Cognito)

O Amazon Cognito é responsável por autenticar os usuários e emitir **tokens JWT**, que são utilizados pelas APIs para identificar e autorizar as requisições, sem manter estado de sessão no backend.

Após a autenticação, o Cognito retorna três tokens principais:

- **Access Token**
  - Utilizado nas chamadas às APIs (`Authorization: Bearer <token>`)
  - Contém informações de autorização (escopos e permissões)
  - É o token validado pelas APIs de Upload e Download

- **ID Token**
  - Representa a identidade do usuário autenticado
  - Contém atributos como e-mail e identificador único
  - Utilizado para fins de identificação e rastreabilidade

- **Refresh Token**
  - Utilizado para renovar os tokens expirados
  - Não é enviado às APIs
  - Usado apenas pelo cliente (frontend ou API consumer)

#### Identificador do Usuário (`user_id`)

A claim `sub` presente nos tokens JWT é utilizada como o **identificador único do usuário (`user_id`)** em toda a aplicação.

Esse identificador é usado para:
- Associar uploads e jobs a um usuário específico
- Garantir que apenas o dono do job possa consultar status ou realizar downloads
- Manter isolamento lógico entre usuários sem necessidade de banco de sessões

#### Fluxo Simplificado de Autenticação

```text
1) Usuário se autentica no Amazon Cognito
2) Cognito emite tokens JWT
3) Cliente envia o Access Token para a API
4) API valida assinatura e issuer do token
5) API extrai o user_id (claim `sub`) e processa a requisição
```

Esse modelo permite uma arquitetura **stateless**, escalável e alinhada com boas práticas de segurança em ambientes cloud-native.

---

## 🔄 Modelo de Processamento Assíncrono

- O serviço de Upload publica mensagens de job no **Amazon SQS**
- O serviço Processador consome os jobs de forma assíncrona
- Falhas são encaminhadas para uma **Dead Letter Queue (DLQ)**
- O serviço Processador não possui tráfego de entrada (inbound)

---

## 💾 Estratégia de Armazenamento

- O **Amazon S3** é utilizado exclusivamente para armazenamento binário
  - `input/` – arquivos enviados pelos usuários
  - `output/` – resultados processados
- O acesso aos arquivos é feito via **URLs pré-assinadas (pre-signed URLs)**
- As decisões de autorização são realizadas pelas APIs, e não pelo S3

---

## 📤 Outputs de Infraestrutura (Referência para os Serviços)

Após o provisionamento da infraestrutura via Terraform, os seguintes **outputs** são disponibilizados e devem ser utilizados pelos serviços de aplicação (Upload, Download e Processor):

### Autenticação (Amazon Cognito)
- **cognito_user_pool_id** – Identificador do User Pool
- **cognito_user_pool_client_id** – Client ID utilizado na autenticação
- **cognito_issuer_url** – Issuer utilizado na validação dos tokens JWT
- **cognito_jwks_url** – Endpoint público das chaves para validação da assinatura dos tokens

### Banco de Dados
- **db_endpoint** – Endpoint do PostgreSQL
- **db_port** – Porta do banco de dados
- **db_name** – Nome do banco
- **db_secret_arn** – ARN do segredo no AWS Secrets Manager com as credenciais

### Mensageria
- **jobs_queue_url / jobs_queue_arn** – Fila principal de jobs
- **jobs_dlq_url / jobs_dlq_arn** – Dead Letter Queue para falhas

### Armazenamento
- **media_bucket_name / media_bucket_arn** – Bucket de mídia
- **media_input_prefix** – Prefixo para arquivos de entrada
- **media_output_prefix** – Prefixo para arquivos processados

### Containers e Logs
- **ecr_upload_repo_url**
- **ecr_download_repo_url**
- **ecr_processor_repo_url**
- **log_group_upload**
- **log_group_download**
- **log_group_processor**

### ECS Task Definitions

Atualmente, a infraestrutura possui as seguintes **Task Definitions registradas no Amazon ECS**:

- **hackathon-upload**
  - API de Upload
  - Exposição da porta 8000
  - Preparada para integração com ALB
  - Logs em `/ecs/hackathon/upload`

- **hackathon-download**
  - API de Download
  - Exposição da porta 8000
  - Preparada para integração com ALB
  - Logs em `/ecs/hackathon/download`

- **hackathon-processor**
  - Worker assíncrono
  - Sem tráfego de entrada (inbound)
  - Consumo de mensagens via SQS
  - Logs em `/ecs/hackathon/processor`

Essas definições descrevem **como os containers serão executados**, mas não iniciam execução automaticamente. A execução ocorrerá somente após a criação dos **ECS Services**.

### IAM Roles (ECS)

- **hackathon-ecs-execution-role**
  - Role utilizada pelo ECS (agent)
  - Responsável por:
    - Pull de imagens no Amazon ECR
    - Envio de logs para o CloudWatch Logs
    - Leitura de segredos no AWS Secrets Manager para injeção em containers

- **hackathon-ecs-application-role**
  - Role utilizada pela aplicação (código dentro do container)
  - Responsável por:
    - Publicação e consumo de mensagens no Amazon SQS
    - Acesso aos objetos no Amazon S3 (input/output)
  - Implementa o princípio de *least privilege* para os microserviços

Esses outputs permitem que os serviços sejam configurados **sem hardcode**, mantendo a separação entre infraestrutura e aplicação.

---

## 🚀 Serviços de Execução e Balanceamento de Carga

Esta seção descreve os serviços de execução da aplicação e o mecanismo de balanceamento de carga adotado na arquitetura, validando o funcionamento ponta a ponta dos microserviços em ambiente cloud.

### Serviços Ativos

- **hackathon-upload**
  - Desired tasks: 1
  - Running tasks: 1
  - Endpoint: `/upload/health`

- **hackathon-download**
  - Desired tasks: 1
  - Running tasks: 1
  - Endpoint: `/download/health`

- **hackathon-processor**
  - Serviço assíncrono
  - `desired_count = 0` (ativado sob demanda)
  - Pode ser escalado sob demanda

### Load Balancer e Health Checks

O Application Load Balancer realiza o roteamento das requisições com base no path:

- `/upload/*` → serviço **hackathon-upload**
- `/download/*` → serviço **hackathon-download**

Os health checks foram configurados no endpoint `/health` de cada serviço e retornam **HTTP 200**, confirmando o estado saudável das tasks.

### Validação Manual (Exemplo)

```bash
curl http://<ALB_DNS_NAME>/upload/health
curl http://<ALB_DNS_NAME>/download/health
```

Resposta esperada:

```text
HTTP/1.1 200 OK
upload ok

HTTP/1.1 200 OK
download ok
```
---

## ☁️ Serviços AWS Utilizados

- Amazon VPC (customizada, sem NAT Gateway)
- Amazon ECS (Fargate)
- Application Load Balancer (ALB)
- Amazon RDS (PostgreSQL)
- Amazon SQS + DLQ
- Amazon S3
- Amazon ECR
- Amazon Cognito
- AWS Secrets Manager

---

## 📌 Observações para o Hackathon

- O API Gateway foi **intencionalmente não utilizado** para reduzir complexidade e custo
- O ALB oferece integração nativa com ECS e roteamento por path
- A arquitetura permite evolução futura (API Gateway, Lambda, WAF, etc.) sem refatorações significativas

---

## 👥 Time – The Code Crafters
