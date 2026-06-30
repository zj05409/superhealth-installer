# SuperHealth Customer Installer

Public bootstrap script for customer-managed SuperHealth deployments.

The script does not contain private keys, tokens, or SuperHealth source code.
Access to the private SuperHealth repository is granted by a customer-specific
read-only GitHub deploy key that is fetched once from the operator activation
service.

## Customer Install

Run the activation command provided by the SuperHealth operator:

```bash
curl -fsSL https://ops.example.com/install/<activation-token> | bash
```

The activation command downloads `customer_superhealth.sh`, fetches the deploy
key once, installs system dependencies, clones SuperHealth, starts services, and
validates the deployment.

After first install, use the persistent command on the customer server:

```bash
superhealth status
superhealth upgrade
superhealth validate
superhealth rollback
```

## Manual Usage

For manual testing:

```bash
curl -fsSL https://raw.githubusercontent.com/zj05409/superhealth-installer/main/customer_superhealth.sh -o customer_superhealth.sh
bash customer_superhealth.sh --help
```
