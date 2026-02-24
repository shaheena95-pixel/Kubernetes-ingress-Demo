#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#   HiQode — AWS Load Balancer Controller Installation
#   Cluster : my-eks-cluster
#   Region  : us-east-1
#   Mode    : EC2 Admin IAM Role (No Service Account needed)
# ═══════════════════════════════════════════════════════════════
#   Connect kubectl
aws eks update-kubeconfig \
  --region us-east-1 \
  --name my-eks-cluster

# ─────────────────────────────────────────────
#  STEP 1 — Associate OIDC Provider
#  Links your EKS cluster to AWS IAM
#  Run this ONLY ONCE per cluster
# ─────────────────────────────────────────────

eksctl utils associate-iam-oidc-provider \
  --region us-east-1 \
  --cluster my-eks-cluster \
  --approve


# ─────────────────────────────────────────────
#  STEP 2 — Add EKS Helm Repo
# ─────────────────────────────────────────────

helm repo add eks https://aws.github.io/eks-charts
helm repo update


# ─────────────────────────────────────────────
#  STEP 3 — Install ALB Controller
#  No Service Account needed — EC2 Admin Role
#  handles all permissions automatically
# ─────────────────────────────────────────────

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster


# ─────────────────────────────────────────────
#  STEP 4 — Verify Controller is Running
#  Wait 30 seconds after install, then run this
# ─────────────────────────────────────────────

kubectl get pods -n kube-system | grep aws-load-balancer


# ═══════════════════════════════════════════════════════════════
#  EXPECTED OUTPUT ✅
#
#  aws-load-balancer-controller-xxxxxxxxx   1/1   Running   0   30s
#  aws-load-balancer-controller-xxxxxxxxx   1/1   Running   0   30s
#
#  2 pods running = Controller installed successfully!
# ═══════════════════════════════════════════════════════════════


# ─────────────────────────────────────────────
#  TROUBLESHOOTING — If pods are not running
# ─────────────────────────────────────────────

# Check pod logs
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

# Check all pods in kube-system
kubectl get pods -n kube-system

# Describe the pod for errors
kubectl describe pod -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller


# ─────────────────────────────────────────────
#  IF YOU NEED TO REINSTALL
# ─────────────────────────────────────────────

# Uninstall first
helm uninstall aws-load-balancer-controller -n kube-system

# Then re-run Step 3


# ═══════════════════════════════════════════════════════════════
#  ⚠️  NOTE FOR STUDENTS
#
#  Demo / Learning → EC2 Admin Role = OK ✅
#
#  Production      → NEVER use Admin Role ❌
#                    Always create:
#                    1. IAM Policy  (minimum permissions)
#                    2. IAM Service Account
#                    3. Attach policy to service account
#                    This is called "Least Privilege Principle"
# ═══════════════════════════════════════════════════════════════
