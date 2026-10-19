import sys
import pandas as pd

# replace strings with your relevant paths.
SRC = r"C:\Users\anonymous\Projects\ai in healthcare\mimic-iii-data\icu_first24hours_adults.csv"
OUT = r"C:\Users\anonymous\Projects\ai in healthcare\mimic-iii-data\icu_first24h_features.parquet"

src = sys.argv[1] if len(sys.argv) > 1 else SRC
df = pd.read_csv(src)
df.to_parquet(OUT)
print(f"wrote {OUT}  ({len(df):,} rows, {df.shape[1]} cols)")
