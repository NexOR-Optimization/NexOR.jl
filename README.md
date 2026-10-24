# NexOR.jl

Solve JuMP models through the public API at `https://api.nexoropt.com`.
Executions, results, accounts, API keys, credits and problem records share this
API root. NexOR.jl needs only this address and the customer's Solve API key.
The API routes requests to the execution service or Odoo internally.

```julia
using JuMP
import NexOR

# NEXOR_API_KEY contains the Solve API key created in the customer portal.
model = Model(NexOR.Optimizer)
set_attribute(model, "solver", "HiGHS")
set_time_limit_sec(model, 120)
@variable(model, 0 <= x <= 4)
@variable(model, 0 <= y <= 3)
@constraint(model, x + y <= 5)
@objective(model, Max, 2x + y)
optimize!(model)
solution_summary(model)
```

The default API URL is `https://api.nexoropt.com`.
`NEXOR_SERVER_URL` or the `server_url` optimizer attribute can override it.
The `api_key` attribute can override `NEXOR_API_KEY`.

The hostname and `/solve/v1` API are independent of the deployment. Moving the
service to another VPS or Kubernetes changes DNS and server configuration;
released clients keep the same URL and request/response protocol. Servers must
preserve existing keys, job records and results during that migration.

## Production smoke test

1. Sign into [NexOR's API Keys page](https://www.nexoropt.com/my/solve/keys)
   using the account you want to test. Your existing website login can be used.
   Enter `NexOR.jl smoke test` as the key name and click **Create key**. Copy the
   key shown once into your password manager.
2. In Odoo's backend, open **Solve → Customers**, remove the default **Solve
   Customers** filter if needed, and open the contact for that login. On its
   **Solve** tab, ensure the account is active and entitled to `highs-mof`.
   Use **Grant Credits** if it needs credits for the configured solver price
   and a 120-second reservation, then click **Push Now**. Leave the customer's
   webhook URL empty for this test: customer webhook delivery is not implemented
   by this execution service yet.
3. From this checkout, instantiate the test environment once:

   ```sh
   julia --project=test -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
   ```

4. Run the test with the following Bash commands. The key prompt is hidden and
   keeps the value out of shell history:

   ```bash
   read -rsp 'NexOR Solve API key: ' nexor_test_key
   printf '\n'
   NEXOR_TEST_PRODUCTION=1 NEXOR_API_KEY="$nexor_test_key" \
     julia --startup-file=no --project=test test/production.jl
   unset nexor_test_key
   ```

The test creates three executions using the account's current pricing. It checks
an LP with objective 9, a MIP with objective 3, and an infeasible model, then reads
each corresponding Odoo record through the same public API. A successful run
reports 18 passing assertions and prints the three problem IDs, which can also be found
in **Solve → Operations → Problems**.

The website link above is for creating the key interactively. The library and
test use only `api.nexoropt.com`; they need neither Odoo's backend address nor its
edge secret. Service credentials, edge headers and webhook signing secrets are
configured on the servers.

Normal tests do not contact production. `test/runtests.jl` includes this smoke
test only when `NEXOR_TEST_PRODUCTION=1` is explicitly set.

The package's `src/` contains only client-side optimizer, serialization and HTTP
code. The small backend under `test/server/` uses the test environment, runs
HiGHS locally without Odoo and emulates the responses the client consumes.
The production worker in `kamal-solve` has its own implementation. Neither
backend depends on NexOR.jl to execute solvers or encode their results.
