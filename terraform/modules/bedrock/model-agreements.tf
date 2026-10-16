locals {
  bedrock_agreement_entries = var.enable_bedrock_model_agreements ? {
    for model_id, offer_id in var.model_agreements :
    "${model_id}|${offer_id}" => {
      model_id = model_id
      offer_id = offer_id
    }
    if offer_id != ""
  } : {}
}

data "aws_bedrock_foundation_model_agreement_offers" "approved" {
  for_each = {
    for _, entry in local.bedrock_agreement_entries : entry.model_id => entry
  }

  model_id   = each.key
  offer_type = "PUBLIC"
}

resource "aws_bedrock_foundation_model_agreement" "approved" {
  for_each = local.bedrock_agreement_entries_to_create

  model_id = each.value.model_id
  offer_token = one([
    for offer in data.aws_bedrock_foundation_model_agreement_offers.approved[each.value.model_id].offers :
    offer.offer_token if offer.offer_id == each.value.offer_id
  ])

  lifecycle {
    ignore_changes = [offer_token]

    precondition {
      condition = length([
        for offer in data.aws_bedrock_foundation_model_agreement_offers.approved[each.value.model_id].offers :
        offer.offer_id if offer.offer_id == each.value.offer_id
      ]) == 1
      error_message = "Approved Bedrock offer ID ${each.value.offer_id} for ${each.value.model_id} is not available in this account/Region; discover current PUBLIC offers before apply."
    }
  }
}
