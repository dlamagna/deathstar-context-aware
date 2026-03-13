import http from 'k6/http';
import { check } from 'k6';
import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// Load mode configuration: 'vu' (default, backwards compatible) or 'rps'
//
// VU mode (K6_LOAD_MODE='vu', default):
//   - K6_TARGET: number of virtual users (default 40)
//   - Open-ended throughput — actual RPS depends on response time (closed loop).
//   - Stages: 60% VUs (30s warmup) → 90% VUs (30s ramp) → 100% VUs (sustained) → cooldown
//
// RPS mode (K6_LOAD_MODE='rps'):
//   - K6_RPS: target requests per second (default 45)
//   - K6_RPS_PRE_ALLOC_VUS: pre-allocated VUs for executor (default 200)
//   - K6_RPS_MAX_VUS: max VUs the executor may spin up (default 400)
//   - Open-loop (constant arrival rate): k6 sends at the fixed rate regardless of
//     response time. Slow responses accumulate as latency/errors, not reduced throughput.
//   - Stages (ramping-arrival-rate):
//       30s  ramp 0 → 60% of K6_RPS  (warmup)
//       30s  ramp    → 100% of K6_RPS (full load)
//       EXPERIMENT_DURATION  hold at K6_RPS   (sustained)
//       30s  ramp    → 0              (cooldown)
//
// Why RPS mode for HPA comparison experiments:
//   In VU mode the request rate is a function of response latency (throughput = VUs /
//   response_time). When one HPA configuration is slower during ramp-up, it receives
//   fewer requests per second, which in turn reduces CPU pressure on upstream services
//   and delays their scaling — a feedback loop that confounds the comparison.
//   RPS mode decouples input load from response time, so both HPA configurations face
//   an identical workload and the comparison is fair.

const LOAD_MODE = __ENV.K6_LOAD_MODE || 'vu';
const STAGE_DURATION = __ENV.EXPERIMENT_DURATION || '10m';  // NOTE: must NOT be K6_DURATION — that's a k6 native env var that overrides options.scenarios
const REQUEST_TIMEOUT = __ENV.K6_TIMEOUT || '5s';

let options;

if (LOAD_MODE === 'rps') {
    const RPS_TARGET = Number(__ENV.K6_RPS || 45);
    const PRE_ALLOC_VUS = Number(__ENV.K6_RPS_PRE_ALLOC_VUS || 200);
    const MAX_VUS = Number(__ENV.K6_RPS_MAX_VUS || 400);
    const rps60 = Math.round(RPS_TARGET * 0.6);

    options = {
        scenarios: {
            ramping_rps: {
                executor: 'ramping-arrival-rate',
                startRate: 0,
                timeUnit: '1s',
                preAllocatedVUs: PRE_ALLOC_VUS,
                maxVUs: MAX_VUS,
                stages: [
                    { duration: '30s', target: rps60 },       // warmup ramp
                    { duration: '30s', target: RPS_TARGET },   // ramp to full load
                    { duration: STAGE_DURATION, target: RPS_TARGET }, // sustained
                    { duration: '30s', target: 0 },            // cooldown
                ],
            },
        },
    };
} else {
    // VU mode (default, backwards compatible with original script)
    const STAGE_TARGET = Number(__ENV.K6_TARGET || 40);

    options = {
        vus: STAGE_TARGET,
        stages: [
            { duration: '30s', target: Math.floor(STAGE_TARGET * 0.6) },
            { duration: '30s', target: Math.floor(STAGE_TARGET * 0.9) },
            { duration: STAGE_DURATION, target: STAGE_TARGET },
            { duration: '1m', target: 1 },
        ],
    };
}

export { options };

const nginx_host = __ENV.NGINX_HOST || '172.18.0.2:31031'; //'147.83.130.67:30177'
const baseURL = `http://${nginx_host}/wrk2-api/post/compose`;

function generatePostData(userIndex) {
    let text = randomString(256);
    let userMention = `@username_${randomIntBetween(1, 1000)}`;
    let url = `http://${randomString(10)}.com`;

    let postData = {
        username: `username_${userIndex}`,
        user_id: userIndex,
        text: `${text} ${userMention} ${url}`,
        media_ids: `["123456789012345678"]`,
        media_types: `["png"]`,
        post_type: 0
    };

    return Object.keys(postData)
        .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(postData[key])}`)
        .join('&');
}

export default function () {
    let userIndex = randomIntBetween(1, 1000);
    let body = generatePostData(userIndex);

    let params = {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        timeout: REQUEST_TIMEOUT,  // Configurable timeout via K6_TIMEOUT environment variable
    };

    let res = http.post(baseURL, body, params);

    check(res, {
        'is status 200': (r) => r.status === 200,
    });
}
