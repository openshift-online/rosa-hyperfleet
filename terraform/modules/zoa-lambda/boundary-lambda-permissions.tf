resource "aws_lambda_permission" "boundary_task_function_url" {
  statement_id           = "AllowBoundaryTaskRole-${replace(var.cluster_id, "-", "")}"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.arn
  principal              = aws_iam_role.task.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "boundary_task_invoke_function" {
  statement_id             = "AllowBoundaryTaskRoleInvoke-${replace(var.cluster_id, "-", "")}"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.api.arn
  principal                = aws_iam_role.task.arn
  invoked_via_function_url = true
}
