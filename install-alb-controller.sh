#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════
#
#   HiQode — AWS Load Balancer Controller — FRESH INSTALLATION GUIDE
#
#   Cluster : my-eks-cluster
#   Region  : us-east-1
#   Nodes   : t2.medium x 2
#
# ───────────────────────────────────────────────────────────────────────────
#   WHAT IS ALB CONTROLLER?
# ───────────────────────────────────────────────────────────────────────────
#
#   When you apply an Ingress manifest in Kubernetes,
#   something needs to READ that manifest and actually
#   CREATE the ALB (Load Balancer) in your AWS account.
#
#   That "something" is the AWS Load Balancer Controller.
#   It is a POD running inside your EKS cluster that:
#   → Watches for Ingress resources
#   → Calls AWS APIs to create/manage ALBs automatically
#
#   Without Controller → kubectl apply ingress ✅ (yaml saved)
#                      → But NO ALB created in AWS ❌
#                      → ADDRESS column stays empty ❌
#                      → Students cannot access the app ❌
#
#   With Controller    → kubectl apply ingress ✅
#                      → ALB created in AWS ✅
#                      → ADDRESS shows URL ✅
#                      → App accessible in browser ✅
#
# ───────────────────────────────────────────────────────────────────────────
#   CORRECT ORDER — WHY THIS ORDER MATTERS
# ───────────────────────────────────────────────────────────────────────────
#
#   We MUST follow this exact order:
#
#   1. OIDC Provider     → Allow EKS to talk to AWS IAM
#   2. Download Policy   → Get the list of permissions needed
#   3. Create Policy     → Register permissions in AWS IAM
#   4. Attach Policy     → Give Worker Nodes those permissions
#   5. Install Helm      → Package manager to install controller
#   6. Add Helm Repo     → Tell Helm where to get the controller
#   7. Helm Install      → Deploy controller pod into cluster
#   8. Verify            → Confirm pods are running
#   9. Apply Ingress     → Now ALB will be created automatically
#
#   WHY THIS ORDER?
#   Steps 1-4 set up PERMISSIONS first.
#   Step 7 installs the controller AFTER permissions are ready.
#   This way the controller starts with correct permissions from day 1.
#   No restart needed. No errors. Clean first-time setup. ✅
#
# ═══════════════════════════════════════════════════════════════════════════


# ───────────────────────────────────────────────────────────────────────────
#  STEP 1 — Associate OIDC Provider with your EKS Cluster
#
#  WHAT IS OIDC?
#  OIDC = OpenID Connect
#  It is a way for AWS IAM to TRUST and IDENTIFY your EKS cluster.
#
#  WHY DO WE NEED THIS?
#  The ALB Controller is a pod running inside Kubernetes.
#  When this pod tries to create ALBs, it calls AWS APIs.
#  AWS IAM says → "Who are you? I don't know any Kubernetes pod!"
#
#  OIDC creates a BRIDGE between your EKS cluster and AWS IAM.
#  After this step, AWS IAM will TRUST tokens coming from your cluster.
#
#  WHAT THIS COMMAND DOES:
#  → Finds the OIDC URL that already exists inside your EKS cluster
#    Example URL: https://oidc.eks.us-east-1.amazonaws.com/id/ABC123XYZ
#  → Registers that URL in AWS IAM as a trusted Identity Provider
#  → Now AWS IAM knows your cluster and trusts its identity tokens
#
#  THINK OF IT LIKE:
#  Your EKS cluster is a new employee joining a company.
#  OIDC = HR registering that employee in the company system.
#  Without OIDC → Employee has no record → Cannot access anything ❌
#  With OIDC    → Employee is registered  → Can access systems ✅
#
#  NOTE: Run this ONLY ONCE per cluster.
# ───────────────────────────────────────────────────────────────────────────

eksctl utils associate-iam-oidc-provider \
  --region us-east-1 \
  --cluster my-eks-cluster \
  --approve

# Verify OIDC is registered in AWS IAM
# You should see an entry with your cluster's OIDC URL
aws iam list-open-id-connect-providers


# ───────────────────────────────────────────────────────────────────────────
#  STEP 2 — Download the ALB Controller IAM Policy JSON file
#
#  WHY?
#  The ALB Controller pod needs to perform many actions in AWS:
#  → Create and Delete Load Balancers
#  → Create and manage Target Groups
#  → Describe Subnets and Security Groups
#  → Manage Listeners and Rules
#  → and 50+ more AWS API actions...
#
#  AWS has already written a JSON file with ALL these permissions.
#  We just need to download it. No need to write it manually.
#
#  WHAT IS THIS JSON FILE?
#  It is a document that says:
#  "Allow these specific AWS API actions"
#  Example inside the file:
#  {
#    "Effect": "Allow",
#    "Action": ["elasticloadbalancing:CreateLoadBalancer", ...]
#  }
#
#  This is just a FILE on your machine right now.
#  It has no effect in AWS yet. Next step will register it in AWS.
# ───────────────────────────────────────────────────────────────────────────

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Confirm the file downloaded successfully
ls -lh iam_policy.json


# ───────────────────────────────────────────────────────────────────────────
#  STEP 3 — Create the IAM Policy inside AWS
#
#  WHY?
#  In Step 2 we only DOWNLOADED the policy as a JSON file.
#  That file is just sitting on your machine — AWS doesn't know about it yet.
#
#  This step REGISTERS that policy inside AWS IAM.
#  After this, the policy exists in AWS and can be attached to roles.
#
#  THINK OF IT LIKE:
#  Step 2 = You wrote a list of permissions on paper (just a document)
#  Step 3 = You submitted that paper to HR and got an official Policy ID
#
#  After this step, you can see the policy in:
#  AWS Console → IAM → Policies → AWSLoadBalancerControllerIAMPolicy
# ───────────────────────────────────────────────────────────────────────────

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json \
  --region us-east-1


# ───────────────────────────────────────────────────────────────────────────
#  STEP 4 — Attach the Policy to the Worker Node IAM Role
#
#  IMPORTANT CONCEPT — TWO DIFFERENT MACHINES, TWO DIFFERENT ROLES:
#  ─────────────────────────────────────────────────────────────────
#
#  Your EC2 (where you run commands)
#  └── Has: Admin IAM Role
#  └── This is YOUR machine — you have full access ✅
#
#  EKS Worker Nodes (where pods run)
#  └── Has: NodeInstanceRole (auto-created by eksctl)
#  └── This role has NO ALB permissions by default ❌
#  └── ALB Controller pod runs HERE — not on your EC2!
#
#  So even though your EC2 has Admin role,
#  the ALB Controller pod runs on WORKER NODES.
#  Worker Nodes use NodeInstanceRole → which has NO ALB permissions.
#  That is why we get 403 AccessDenied errors without this step!
#
#  BY ATTACHING THE POLICY TO NodeInstanceRole:
#  Worker Nodes → now have ALB permissions ✅
#  ALB Controller pod runs on Worker Node ✅
#  Pod calls AWS API to create ALB ✅
#  ALB gets created ✅
#
#  HOW TO FIND YOUR NODE ROLE NAME:
#  aws iam list-roles | grep NodeInstanceRole
#
#  YOUR VALUES:
#  Role Name  : eksctl-my-eks-cluster-nodegroup-my-NodeInstanceRole-zmPRf39npNpJ
#  Account ID : 865189140490
# ───────────────────────────────────────────────────────────────────────────

aws iam attach-role-policy \
  --role-name eksctl-my-eks-cluster30-nodegroup--NodeInstanceRole-8gjXQaUhReTI\
  --policy-arn arn:aws:iam::773391562788:policy/AWSLoadBalancerControllerIAMPolicy \
  --region us-east-1

# Verify — you should see AWSLoadBalancerControllerIAMPolicy in the output
aws iam list-attached-role-policies \
  --role-name eksctl-my-eks-cluster-nodegroup-my-NodeInstanceRole-zmPRf39npNpJ


# ───────────────────────────────────────────────────────────────────────────
#  STEP 5 — Install Helm
#
#  WHAT IS HELM?
#  Helm is a Package Manager for Kubernetes.
#
#  Just like:
#  apt  → installs software on Ubuntu Linux
#  npm  → installs packages for Node.js
#  pip  → installs packages for Python
#  Helm → installs applications on Kubernetes
#
#  WHY USE HELM FOR ALB CONTROLLER?
#  Installing the ALB Controller manually requires 20+ YAML files.
#  Helm packages all of them into ONE single command.
#  It handles:
#  → Deployments, Services, RBAC, Webhooks, ConfigMaps
#  → Correct versions and dependencies
#  → Easy upgrades and uninstalls later
#
#  In short: Helm makes complex Kubernetes installations simple.
# ───────────────────────────────────────────────────────────────────────────

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify Helm is installed — should print the version number
helm version


# ───────────────────────────────────────────────────────────────────────────
#  STEP 6 — Add the AWS EKS Helm Repository
#
#  WHY?
#  Helm needs to know WHERE to download packages from.
#  This command adds the official AWS EKS repository to Helm.
#
#  helm repo add    → Registers a new package source
#  helm repo update → Downloads the latest package list from all sources
#
#  THINK OF IT LIKE UBUNTU:
#  sudo add-apt-repository ppa:some-repo  → adds a new source
#  sudo apt-get update                    → refreshes the package list
#
#  After this, Helm knows about all packages in the EKS repository
#  including the ALB Controller, which we install in the next step.
# ───────────────────────────────────────────────────────────────────────────

helm repo add eks https://aws.github.io/eks-charts
helm repo update


# ───────────────────────────────────────────────────────────────────────────
#  STEP 7 — Install the ALB Controller
#
#  THIS IS THE KEY STEP — WHY IT WORKS NOW WITHOUT ERRORS:
#  ─────────────────────────────────────────────────────────
#  We completed Steps 1-4 BEFORE installing the controller.
#  So the IAM permissions are already in place on the Worker Nodes.
#  When the controller pod starts for the FIRST TIME,
#  it already has all required ALB permissions from NodeInstanceRole.
#  No errors. No restart needed. Clean start. ✅
#
#  WHAT HELM CREATES INSIDE YOUR CLUSTER:
#  → 2 ALB Controller pods (for high availability)
#  → ServiceAccount, ClusterRole, ClusterRoleBinding
#  → Webhooks for Ingress validation
#  → All other required Kubernetes resources
#
#  --set clusterName=my-eks-cluster
#  → Tells the controller which EKS cluster it belongs to
#  → Controller uses this to tag ALBs it creates in AWS
#  → Without this → controller won't know which cluster to manage
#
#  -n kube-system
#  → Installs in the kube-system namespace
#  → This is where all Kubernetes system-level components live
#  → Examples: kube-dns, kube-proxy, aws-node are all in kube-system
# ───────────────────────────────────────────────────────────────────────────

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster


# ───────────────────────────────────────────────────────────────────────────
#  STEP 8 — Verify the Controller Pods are Running
#
#  WHY VERIFY BEFORE APPLYING INGRESS?
#  The ALB Controller pod is what READS your Ingress file
#  and CREATES the ALB in AWS.
#
#  If the pod is not Running:
#  → Ingress file will apply but nothing will happen
#  → No ALB will be created
#  → ADDRESS column will stay empty
#  → You will waste time debugging
#
#  So ALWAYS verify the controller is Running FIRST.
#  Then apply the Ingress file.
#
#  Wait about 30 seconds after Step 7 before running this.
# ───────────────────────────────────────────────────────────────────────────

kubectl get pods -n kube-system | grep aws-load-balancer

# ═══════════════════════════════════════════════════════════════════════════
#  EXPECTED OUTPUT ✅
#
#  NAME                                          READY   STATUS    RESTARTS
#  aws-load-balancer-controller-xxxxxxxxx-xxx    1/1     Running   0
#  aws-load-balancer-controller-xxxxxxxxx-xxx    1/1     Running   0
#
#  2 pods = Running = Controller is healthy ✅
#  RESTARTS = 0     = Started clean with correct permissions ✅
#  Now you are ready to apply the Ingress file!
# ═══════════════════════════════════════════════════════════════════════════


# ───────────────────────────────────────────────────────────────────────────
#  STEP 9 — Apply Ingress and Watch ALB get Created
#
#  WHAT HAPPENS WHEN YOU APPLY INGRESS:
#  1. kubectl sends the Ingress YAML to Kubernetes API
#  2. ALB Controller detects this new Ingress resource
#  3. It reads the annotations (scheme, target-type, ports etc.)
#  4. It calls AWS API → Create Application Load Balancer
#  5. AWS provisions the ALB in your VPC (takes 2-3 minutes)
#  6. ALB URL gets written back into the Ingress ADDRESS field
#  7. You can now access your apps via the ALB URL!
# ───────────────────────────────────────────────────────────────────────────

kubectl apply -f 04-ingress.yaml

# Watch live — ALB URL will appear in ADDRESS column within 2-3 minutes
# Press Ctrl+C once you see the ADDRESS populated
kubectl get ingress -n hiqode -w

# ═══════════════════════════════════════════════════════════════════════════
#  EXPECTED OUTPUT ✅
#
#  NAME            CLASS  HOSTS  ADDRESS                                      PORTS  AGE
#  hiqode-ingress  alb    *      k8s-hiqode-xxxx.us-east-1.elb.amazonaws.com  80     2m
#
#  ADDRESS is populated = ALB is created = Demo is LIVE! 🎉
#
#  Test in your browser:
#  http://<ADDRESS>/           → Login Page   🔐
#  http://<ADDRESS>/order      → Order Page   📦
#  http://<ADDRESS>/payment    → Payment Page 💳
# ═══════════════════════════════════════════════════════════════════════════


# ───────────────────────────────────────────────────────────────────────────
#  TROUBLESHOOTING — If something goes wrong
# ───────────────────────────────────────────────────────────────────────────

# Check what the controller pods are doing
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  --tail=50

# Check ingress events — shows exactly what error occurred
kubectl describe ingress hiqode-ingress -n hiqode

# Check all pods in kube-system
kubectl get pods -n kube-system

# Uninstall controller completely and start fresh from Step 7
helm uninstall aws-load-balancer-controller -n kube-system


# ═══════════════════════════════════════════════════════════════════════════
#
#  ⚠️  NOTE FOR STUDENTS — DEMO vs PRODUCTION
#
#  ──────────────────────────────────────────────────────────────────
#  WHAT WE DID TODAY (Demo / Learning approach)
#  ──────────────────────────────────────────────────────────────────
#  → Attached ALB policy to NodeInstanceRole (Worker Node's role)
#  → This is quick and simple for learning ✅
#  → BUT every pod running on that node gets these permissions
#    (not just the ALB controller — ALL pods on the node!)
#  → Too much access = Security risk in real production ❌
#
#  ──────────────────────────────────────────────────────────────────
#  CORRECT WAY IN PRODUCTION (IAM Service Account approach)
#  ──────────────────────────────────────────────────────────────────
#  → Create a dedicated IAM Service Account for ALB Controller only
#  → Only the ALB Controller pod gets these permissions
#  → Other pods on the same node do NOT get ALB permissions
#  → This is called the "LEAST PRIVILEGE PRINCIPLE"
#  → Give ONLY the permissions needed — nothing extra
#
#  Production Commands:
#
#  # Create Service Account with ALB policy attached
#  eksctl create iamserviceaccount \
#    --cluster my-eks-cluster \
#    --namespace kube-system \
#    --name aws-load-balancer-controller \
#    --attach-policy-arn arn:aws:iam::865189140490:policy/AWSLoadBalancerControllerIAMPolicy \
#    --approve \
#    --region us-east-1
#
#  # Install controller using that Service Account
#  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
#    -n kube-system \
#    --set clusterName=my-eks-cluster \
#    --set serviceAccount.create=false \
#    --set serviceAccount.name=aws-load-balancer-controller
#
#  ──────────────────────────────────────────────────────────────────
#  SIMPLE RULE TO REMEMBER
#  ──────────────────────────────────────────────────────────────────
#  Learning  → Attach policy to NodeInstanceRole   (simple)  ✅
#  Production → Use IAM Service Account             (secure)  ✅
#
# ═══════════════════════════════════════════════════════════════════════════
