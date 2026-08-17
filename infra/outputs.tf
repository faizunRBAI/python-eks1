output "cluster_name" {
  description = "EKS cluster name; the deploy derives it as <project>-eks."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version the control plane is running."
  value       = aws_eks_cluster.this.version
}

output "ecr_repository_url" {
  description = "Registry the pipeline pushes application images to."
  value       = aws_ecr_repository.this.repository_url
}

output "vpc_id" {
  description = "VPC that holds the cluster and the database subnets."
  value       = aws_vpc.this.id
}

output "node_group_name" {
  description = "Managed node group backing the workloads."
  value       = aws_eks_node_group.this.node_group_name
}
