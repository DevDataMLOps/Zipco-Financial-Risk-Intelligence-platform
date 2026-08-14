# Data Availability

This Git repository does not contain the large generated CSV datasets, the original one-million-row source extract, or the supplied data-dictionary PDF.

They are excluded because:

- Generated data is reproducible from the included deterministic generator.
- Large data objects belong in S3 or an artifact store rather than ordinary Git history.
- The supplied reference PDF is preserved in the governed S3 metadata zone and is not redistributed here.

## Expected relational-v2 populations

| Table | Rows |
|---|---:|
| Customers | 100,000 |
| Accounts | 150,000 |
| Transactions | 1,000,000 |
| Transaction categories | 10 |
| Categorized transactions | 1,000,000 |
| Market data | 87,140 |

Use [`../platform/data-generation/generate_zipco_relational_v2.py`](../platform/data-generation/generate_zipco_relational_v2.py) with the appropriate source inputs to rebuild the dataset. The contracts and verified quality results are included in the phase directories.

