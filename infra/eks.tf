# ── Envelope encryption for Kubernetes Secrets ────────────────────────────────

resource "aws_kms_key" "eks" {
  description             = "EKS Secret envelope encryption for ${local.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ── Control plane ─────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # The audit trail an incident review actually needs.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # The pipeline's IAM identity creates the cluster, so this is what lets the
    # configure stage run kubectl without any aws-auth ConfigMap surgery.
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    # CI runners have no fixed egress address, so the API server endpoint stays
    # publicly reachable and is protected by IAM authentication plus the audit
    # log above. Restrict this to your runner's CIDR range if you move to
    # self-hosted runners. See .trivyignore for the recorded exception.
    endpoint_public_access = true
    public_access_cidrs    = ["0.0.0.0/0"]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ── Managed node group ────────────────────────────────────────────────────────

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    # Pull permission for the ECR repository this stack creates.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = 1
    max_size     = var.node_desired_size + 2
  }

  update_config {
    # Node replacements drain one at a time so the service stays up.
    max_unavailable = 1
  }

  labels = {
    workload = "application"
  }

  lifecycle {
    # The Horizontal Pod Autoscaler changes pod count, not node count, but a
    # cluster autoscaler added later will own desired_size — ignoring drift
    # here keeps terraform from fighting it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ── Core add-ons ──────────────────────────────────────────────────────────────
# Version is left unset so EKS installs the default build for the cluster's
# Kubernetes version; OVERWRITE lets terraform adopt the self-managed copies
# EKS pre-installs.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS needs somewhere to run before it can report healthy.
  depends_on = [aws_eks_node_group.this]
}
