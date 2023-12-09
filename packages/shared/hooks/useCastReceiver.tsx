declare const cast: any;

declare global {
    interface Window {
        __onGCastApiAvailable: (isAvailable: boolean) => void;
    }
}

import { useEffect, useState } from 'react';

type Receiver = {
    cast: typeof cast;
};

const load = (() => {
    let promise: Promise<Receiver> | null = null;

    return () => {
        if (promise === null) {
            promise = new Promise((resolve) => {
                const script = document.createElement('script');
                script.src =
                    'https://www.gstatic.com/cast/sdk/libs/caf_receiver/v3/cast_receiver_framework.js';

                window.__onGCastApiAvailable = (isAvailable) => {
                    if (isAvailable) {
                        resolve({
                            cast,
                        });
                    }
                };
                document.body.appendChild(script);
            });
        }
        return promise;
    };
})();

export const useCastReceiver = () => {
    const [receiver, setReceiver] = useState<Receiver | null>({
        cast: null,
    });

    useEffect(() => {
        load().then((receiver) => {
            setReceiver(receiver);
        });
    });

    return receiver;
};
