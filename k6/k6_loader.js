import http from 'k6/http';
import { check } from 'k6';
import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// Load mode configuration: 'vu' (default, backwards compatible) or 'rps'
//
// VU mode (K6_LOAD_MODE='vu', default):
//   - K6_TARGET: number of virtual users (default 40)
//   - Uses staged ramp-up: 60% -> 90% -> 100% -> cooldown
//
// RPS mode (K6_LOAD_MODE='rps'):
//   - K6_RPS: requests per second (default 30)
//   - K6_RPS_PRE_ALLOC_VUS: pre-allocated VUs (default 100)
//   - K6_RPS_MAX_VUS: max allowed VUs (default 300)
//   - Constant arrival rate with no ramp-up
//

const LOAD_MODE = __ENV.K6_LOAD_MODE || 'vu';
const STAGE_DURATION = __ENV.K6_DURATION || '10m';
const REQUEST_TIMEOUT = __ENV.K6_TIMEOUT || '5s';

let options;

if (LOAD_MODE === 'rps') {
    // RPS mode: constant-arrival-rate executor
    const RPS_TARGET = Number(__ENV.K6_RPS || 30);
    const PRE_ALLOC_VUS = Number(__ENV.K6_RPS_PRE_ALLOC_VUS || 100);
    const MAX_VUS = Number(__ENV.K6_RPS_MAX_VUS || 300);

    options = {
        scenarios: {
            constant_rps: {
                executor: 'constant-arrival-rate',
                rate: RPS_TARGET,
                timeUnit: '1s',
                duration: STAGE_DURATION,
                preAllocatedVUs: PRE_ALLOC_VUS,
                maxVUs: MAX_VUS,
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
