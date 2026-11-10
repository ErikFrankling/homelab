package quota

import (
 "encoding/json"
 "testing"
 "cpa-usage-keeper/internal/cpa/dto/apicall"
)

func TestScopedLimits(t *testing.T) {
 body := `{"five_hour":null,"seven_day":{"utilization":100},"limits":[{"kind":"weekly_all","percent":100},{"kind":"weekly_scoped","group":"weekly","percent":0,"scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}]}`
 // Exercise the actual provider parser, not only the normalized output.
 var response apicall.Response
 raw, _ := json.Marshal(map[string]any{"status_code":200,"body":body})
 if err := json.Unmarshal(raw, &response); err != nil { t.Fatal(err) }
 usage, err := parseClaudeUsagePayload(&response)
 if err != nil { t.Fatal(err) }
 rows := normalizeClaudeQuotaRows(ClaudeResult{Usage:usage})
 if len(rows)!=2 { t.Fatalf("wanted Fable and weekly, got %#v", rows) }
 if rows[0].Label!="Fable · 7 days" || rows[0].UsedPercent==nil || *rows[0].UsedPercent!=0 || rows[0].Active==nil || *rows[0].Active { t.Fatalf("lost inactive zero-usage scope: %#v",rows[0]) }
 if rows[1].Key!="seven_day" {t.Fatal("legacy history key changed")}
}
