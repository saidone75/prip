#!/usr/bin/env bb

;; Author: Marco Marini
;; Description: Verify decoded FLAC audio against prip.sh manifests.
;; License: MIT (see LICENSE)
;; SPDX-License-Identifier: MIT

(require '[babashka.fs :as fs]
         '[babashka.process :as process]
         '[clojure.string :as str])

(defn fail [message] (throw (ex-info message {})))

(defn usage []
  (println "Usage: verify.bb -f ALBUM_OR_LIBRARY")
  (println "Recursively check logs/trial-a/audio.sha256 against album/flac files.")
  (println "Supports .cdda renaming.")
  (println "Audio files are read-only. Save each album report to logs/verify-report.log.")
  (println "Requires flac. Exit: 0 = verified, 1 = errors."))

(defn audio-hash [file]
  ;; Stream decoded samples: memory use does not depend on track length.
  (let [p (process/process ["flac" "--silent" "--decode" "--stdout" "--force-raw-format"
                            "--endian=little" "--sign=signed" "--" (str file)]
                           {:out :stream :err :inherit})
        digest (java.security.MessageDigest/getInstance "SHA-256")
        buffer (byte-array 65536)]
    (try
      (with-open [input (:out p)]
        (loop []
          (let [n (.read input buffer)]
            (when (pos? n)
              (.update digest buffer 0 n)
              (recur)))))
      (when-not (zero? (:exit @p)) (fail (str "FLAC decoding failed: " file)))
      (apply str (map #(format "%02x" (bit-and 255 %)) (.digest digest)))
      (finally (process/destroy p)))))

(defn track-file [album name]
  (let [stem (str/replace name #"(?i)\.wav$" "")
        names (distinct [(str stem ".flac")
                         (str (str/replace stem #"\.cdda$" "") ".flac")])
        matches (filter fs/regular-file? (map #(fs/path album "flac" %) names))]
    (when (> (count matches) 1) (fail (str "Ambiguous FLAC match: " name)))
    (first matches)))

(defn seconds-since [started]
  (/ (- (System/nanoTime) started) 1e9))

(defn check-manifest [manifest]
  (let [album (-> manifest fs/parent fs/parent fs/parent)
        started (System/nanoTime)
        timestamp (str (java.time.Instant/now))
        messages (atom [])
        totals (atom {:verified 0 :skipped 0 :errors 0})
        emit (fn [message] (println message) (flush) (swap! messages conj message))]
    (emit (str "[INFO] Album: " album))
    (emit (str "[INFO] Manifest: " manifest))
    (try
      (let [content (slurp (str manifest))
            lines (str/split-lines content)]
        (when (str/blank? content) (fail "Empty manifest"))
        (doseq [[index line] (map-indexed vector lines)]
          (try
            (let [[_ expected name] (re-matches #"([0-9a-fA-F]{64})  (.+)" line)
                  progress (str "[" (inc index) "/" (count lines) "] ")]
              (when-not (and name (not (str/includes? name "/"))
                             (not (str/includes? name "\\"))
                             (str/ends-with? (str/lower-case name) ".wav"))
                (fail (str "Invalid manifest entry at line " (inc index))))
              (if-let [file (track-file album name)]
                (let [track-start (System/nanoTime)]
                  (emit (str "[INFO] " progress "Checking " (fs/file-name file)))
                  (when-not (= (str/lower-case expected) (audio-hash file))
                    (fail (str "Checksum mismatch: " file)))
                  (swap! totals update :verified inc)
                  (emit (format "[OK] %s%s (%.2f s)" progress (fs/file-name file)
                                (seconds-since track-start))))
                (if (re-matches #"track00(?:\.cdda)?\.wav" name)
                  (do (swap! totals update :skipped inc)
                      (emit (str "[SKIP] " progress name " (discarded pregap)")))
                  (fail (str "Missing FLAC: " name)))))
            (catch Exception e
              (swap! totals update :errors inc)
              (emit (str "[ERROR] " (ex-message e)))))))
      (catch Exception e
        (swap! totals update :errors inc)
        (emit (str "[ERROR] " (ex-message e)))))
    (emit (format "[SUMMARY] %d verified, %d skipped pregaps, %d errors; %.2f s"
                  (:verified @totals) (:skipped @totals) (:errors @totals)
                  (seconds-since started)))
    (let [report (fs/path album "logs" "verify-report.log")
          pending (fs/create-temp-file {:dir (fs/parent report) :prefix ".verify-report."})]
      (try
        (spit (str pending) (str "FLAC verification report\nStarted: " timestamp "\n"
                                 (str/join "\n" @messages) "\n"))
        (fs/move pending report {:replace-existing true :atomic-move true})
        (println "[INFO] Report:" (str report))
        (finally (fs/delete-if-exists pending))))
    @totals))

(try
  (let [args (vec *command-line-args*)]
    (if (#{["-h"] ["--help"]} args)
      (usage)
      (do
        (when-not (and (= 2 (count args)) (= "-f" (first args)))
          (usage) (fail "Specify -f ALBUM_OR_LIBRARY"))
        (when-not (fs/which "flac") (fail "Required command not found: flac"))
        (let [root (fs/absolutize (second args))
              _ (when-not (fs/directory? root) (fail (str "Not a directory: " root)))
              ;; prip.sh compares both reads before publishing; trial-a suffices.
              manifests (->> (fs/glob root "**/audio.sha256")
                             (filter #(and (fs/regular-file? %)
                                           (= "trial-a" (str (fs/file-name (fs/parent %))))
                                           (= "logs" (str (fs/file-name (-> % fs/parent fs/parent))))))
                             (sort-by str))]
          (when (empty? manifests) (fail "No logs/trial-a/audio.sha256 manifests found"))
          (println "[INFO] Found" (count manifests) "albums to verify.")
          (let [started (System/nanoTime)
                results (mapv (fn [manifest]
                                (try (check-manifest manifest)
                                     (catch Exception e
                                       (println "[ERROR]" (str manifest) (ex-message e))
                                       {:verified 0 :skipped 0 :errors 1}))) manifests)
                totals (apply merge-with + results)]
            (println (format "[SUMMARY] %d albums; %d verified tracks, %d skipped pregaps, %d errors; %.2f s"
                             (count manifests) (:verified totals) (:skipped totals) (:errors totals)
                             (seconds-since started)))
            (when (pos? (:errors totals)) (System/exit 1)))))))
  (catch Exception e
    (binding [*out* *err*] (println "[ERROR]" (ex-message e)))
    (System/exit 1)))
