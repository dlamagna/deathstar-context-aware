import http from 'k6/http';
import { check } from 'k6';
import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// export let options = {
//     scenarios: {
//         constant_rps: {
//             executor: 'constant-arrival-rate',
//             rate: 10,  // 10 requests per second
//             timeUnit: '1s',
//             duration: '300s',
//             preAllocatedVUs: 20, // Pre-allocate enough VUs
//             //maxVUs: 10,
//         },
//     },
// };

const STAGE_TARGET = Number(__ENV.K6_TARGET || 40);
const STAGE_DURATION = __ENV.K6_DURATION || '180s';
const REQUEST_TIMEOUT = __ENV.K6_TIMEOUT || '5s';

// Build a short scenario: 30s ramp to half target, hold for (duration-60s) at target, 30s ramp down
function buildStages(total, target) {
    // simple split: 30s warmup, 30s cooldown, rest as steady
    const warm = '30s';
    const cool = '30s';
    let steadySeconds = 0;
    try {
        const m = total.match(/^(\d+)(s)$/);
        if (m) steadySeconds = Math.max(0, parseInt(m[1], 10) - 60);
    } catch (_) {}
    const steady = `${steadySeconds}s`;
    const half = Math.max(1, Math.floor(target / 2));
    return [
        { duration: warm, target: half },
        { duration: steady, target: target },
        { duration: cool, target: 1 },
    ];
}

export const options = {
    stages: buildStages(STAGE_DURATION, STAGE_TARGET),
};

const nginx_host = __ENV.NGINX_HOST || '147.83.130.183:32000';//'147.83.130.67:30177'
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
