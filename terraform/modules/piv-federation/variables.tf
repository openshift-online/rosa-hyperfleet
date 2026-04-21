variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster to configure RBAC access entries on"
  type        = string
}

variable "idp_saml_metadata_xml" {
  description = "Full XML content of the SAML 2.0 metadata document from the PIV/CAC-capable identity provider (e.g., AD FS or Okta). Obtain from your agency IdP administrator."
  type        = string
  sensitive   = true
}
