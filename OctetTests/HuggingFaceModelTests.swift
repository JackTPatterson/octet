import XCTest

final class HuggingFaceModelTests: XCTestCase {
    func testLinksNamesAndCommandsAllMeanTheRepo() {
        let plain = HuggingFaceModel.Reference(owner: "bartowski", repo: "Llama-3.2-1B-Instruct-GGUF")
        XCTAssertEqual(HuggingFaceModel.parse("bartowski/Llama-3.2-1B-Instruct-GGUF"), plain)
        XCTAssertEqual(HuggingFaceModel.parse("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF"), plain)
        XCTAssertEqual(HuggingFaceModel.parse("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/tree/main"), plain)
        XCTAssertEqual(HuggingFaceModel.parse(" hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:q8_0 ")?.quantization, "Q8_0")
        XCTAssertEqual(HuggingFaceModel.parse("ollama run hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M")?.quantization, "Q4_K_M")
        // A file's page says which quantization.
        let file = HuggingFaceModel.parse("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/blob/main/Llama-3.2-1B-Instruct-Q6_K.gguf")
        XCTAssertEqual(file?.repoId, "bartowski/Llama-3.2-1B-Instruct-GGUF")
        XCTAssertEqual(file?.quantization, "Q6_K")
        // Words are a search, not a repo.
        XCTAssertNil(HuggingFaceModel.parse("llama 3"))
        XCTAssertNil(HuggingFaceModel.parse("llama"))
        XCTAssertNil(HuggingFaceModel.parse(""))
        XCTAssertNil(HuggingFaceModel.parse("https://huggingface.co/api/models"))
    }

    func testOllamaAndOpenCodeNames() {
        let reference = HuggingFaceModel.Reference(owner: "bartowski", repo: "gemma-2-9b-it-GGUF", quantization: "Q5_K_M")
        XCTAssertEqual(reference.ollamaName, "hf.co/bartowski/gemma-2-9b-it-GGUF:Q5_K_M")
        XCTAssertEqual(reference.displayName, "gemma-2-9b-it (Q5_K_M)")
        XCTAssertEqual(OpenCodeOllama.modelID(reference.ollamaName), "ollama/hf.co/bartowski/gemma-2-9b-it-GGUF:Q5_K_M")
        XCTAssertEqual(HuggingFaceModel.Reference(owner: "a", repo: "b").ollamaName, "hf.co/a/b")
    }

    func testQuantizationsComeFromTheFileNames() {
        XCTAssertEqual(HuggingFaceModel.quantization(ofFile: "Llama-3.2-1B-Instruct-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(HuggingFaceModel.quantization(ofFile: "gemma-2-9b-it.Q8_0.gguf"), "Q8_0")
        XCTAssertEqual(HuggingFaceModel.quantization(ofFile: "model-iq3_xs.gguf"), "IQ3_XS")
        XCTAssertEqual(HuggingFaceModel.quantization(ofFile: "Big-Q8_0/Big-Q8_0-00001-of-00002.gguf"), "Q8_0")
        XCTAssertEqual(HuggingFaceModel.quantization(ofFile: "model-f16.gguf"), "F16")
        XCTAssertNil(HuggingFaceModel.quantization(ofFile: "mmproj-model-f16.gguf"))
        XCTAssertNil(HuggingFaceModel.quantization(ofFile: "README.md"))
        XCTAssertNil(HuggingFaceModel.quantization(ofFile: "model.gguf"))

        let json: [String: Any] = ["siblings": [
            ["rfilename": "x-Q8_0-00001-of-00002.gguf", "size": 3_000],
            ["rfilename": "x-Q8_0-00002-of-00002.gguf", "size": 1_000],
            ["rfilename": "x-Q4_K_M.gguf", "size": 2_000],
            ["rfilename": "README.md", "size": 10],
        ]]
        let quantizations = HuggingFaceModel.quantizations(in: json)
        XCTAssertEqual(quantizations.map(\.name), ["Q4_K_M", "Q8_0"])
        XCTAssertEqual(quantizations.map(\.bytes), [2_000, 4_000])
        XCTAssertEqual(HuggingFaceModel.suggested(quantizations), "Q4_K_M")
        XCTAssertEqual(HuggingFaceModel.suggested([.init(name: "Q2_K", bytes: 1), .init(name: "Q6_K", bytes: 2), .init(name: "Q8_0", bytes: 3)]), "Q6_K")
        XCTAssertNil(HuggingFaceModel.suggested([]))
    }

    func testSearchResultsAreRepos() {
        let json: [[String: Any]] = [
            ["id": "bartowski/x-GGUF", "downloads": 12, "likes": 3],
            ["modelId": "someone/y-GGUF"],
            ["id": "no-owner"],
        ]
        let repos = HuggingFaceModel.repos(in: json)
        XCTAssertEqual(repos.map(\.id), ["bartowski/x-GGUF", "someone/y-GGUF"])
        XCTAssertEqual(repos[0].downloads, 12)
        XCTAssertEqual(repos[0].owner, "bartowski")
        XCTAssertEqual(HuggingFaceModel.searchURL("llama 3").query?.contains("search=llama%203"), true)
        XCTAssertEqual(HuggingFaceModel.searchURL("x").query?.contains("filter=gguf"), true)
    }

    func testPullProgressLines() {
        XCTAssertEqual(OllamaPull.parse(line: #"{"status":"pulling manifest"}"#)?.text, "Finding the model…")
        let layer = OllamaPull.parse(line: #"{"status":"pulling 1234","digest":"sha256:1234","total":2000,"completed":500}"#)
        XCTAssertEqual(layer?.fraction, 0.25)
        XCTAssertEqual(layer?.text, "500 bytes of 2 KB")
        XCTAssertEqual(OllamaPull.parse(line: #"{"status":"success"}"#)?.isDone, true)
        XCTAssertEqual(OllamaPull.parse(line: #"{"error":"pull model manifest: file does not exist"}"#)?.error,
                       "pull model manifest: file does not exist")
        XCTAssertNil(OllamaPull.parse(line: ""))
        XCTAssertNil(OllamaPull.parse(line: "not json"))
        let body = try? JSONSerialization.jsonObject(with: OllamaPull.body(model: "hf.co/a/b:Q4")) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "hf.co/a/b:Q4")
        XCTAssertEqual(body?["stream"] as? Bool, true)
    }

    func testTheModelIsAddedToOpenCodesOllamaProvider() throws {
        let existing = Data(#"{"model":"anthropic/claude","provider":{"ollama":{"options":{"baseURL":"http://localhost:11434/v1"},"models":{"llama3":{"name":"Llama 3"}}}}}"#.utf8)
        let added = try XCTUnwrap(OpenCodeOllama.registered(existing, model: "hf.co/a/b:Q4_K_M", name: "b (Q4_K_M)"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: added) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "anthropic/claude")
        let ollama = try XCTUnwrap((root["provider"] as? [String: Any])?["ollama"] as? [String: Any])
        XCTAssertEqual(ollama["npm"] as? String, "@ai-sdk/openai-compatible")
        // The person's own address is kept.
        XCTAssertEqual((ollama["options"] as? [String: Any])?["baseURL"] as? String, "http://localhost:11434/v1")
        let models = try XCTUnwrap(ollama["models"] as? [String: Any])
        XCTAssertEqual(models.keys.sorted(), ["hf.co/a/b:Q4_K_M", "llama3"])
        XCTAssertEqual((models["hf.co/a/b:Q4_K_M"] as? [String: Any])?["name"] as? String, "b (Q4_K_M)")

        // From nothing, the provider is made whole.
        let fresh = try XCTUnwrap(OpenCodeOllama.registered(nil, model: "hf.co/a/b", name: "b"))
        let freshRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: fresh) as? [String: Any])
        let freshOllama = try XCTUnwrap((freshRoot["provider"] as? [String: Any])?["ollama"] as? [String: Any])
        XCTAssertEqual((freshOllama["options"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(freshRoot["$schema"] as? String, "https://opencode.ai/config.json")
        // A file that isn't JSON is left alone.
        XCTAssertNil(OpenCodeOllama.registered(Data("{".utf8), model: "m", name: "n"))
    }
}
