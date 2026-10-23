import Foundation
import Testing
@testable import LocalTutor

@Suite("Retrieval benchmark", .serialized)
struct RetrievalBenchmarkTests {
    @Test("Lexical retrieval quality on the study corpus")
    func lexicalBenchmark() async throws {
        let corpus = try await BenchmarkCorpus.make()
        for (tier, questions) in BenchmarkCorpus.tiers {
            let metrics = corpus.metrics(try await corpus.lexicalRankings(questions), questions)
            BenchmarkCorpus.report("\(tier) lexical", metrics)
            #expect(metrics.recallAtFive > 0)
        }
    }

    @Test(
        "Dense and hybrid retrieval quality on the study corpus",
        .enabled(if: ProcessInfo.processInfo.environment["LOCALTUTOR_INTEGRATION"] == "1"),
        .timeLimit(.minutes(30))
    )
    func hybridBenchmark() async throws {
        let corpus = try await BenchmarkCorpus.make()
        let started = ContinuousClock.now
        let entries = try await corpus.embeddedChunks()
        print("[benchmark] embedded \(corpus.chunks.count) chunks in \(ContinuousClock.now - started)")
        for (tier, questions) in BenchmarkCorpus.tiers {
            let lexical = try await corpus.lexicalRankings(questions)
            let dense = try await corpus.denseRankings(questions, entries: entries)
            let hybrid = zip(lexical, dense).map { lexical, dense in
                SourceRetriever.reciprocalRankFusion(lexical: lexical, dense: dense)
            }
            BenchmarkCorpus.report("\(tier) lexical", corpus.metrics(lexical, questions))
            BenchmarkCorpus.report("\(tier) dense", corpus.metrics(dense, questions))
            BenchmarkCorpus.report("\(tier) hybrid", corpus.metrics(hybrid, questions))
            #expect(corpus.metrics(hybrid, questions).recallAtFive > 0)
        }
    }
}

private struct BenchmarkCorpus {
    var indexes: [SourceIndex]
    var repository: SQLiteSourceIndexRepository

    var chunks: [SourceChunk] {
        indexes.flatMap(\.chunks)
    }

    static func make() async throws -> BenchmarkCorpus {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = SQLiteSourceIndexRepository(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )
        var indexes: [SourceIndex] = []
        for (name, text) in sources {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let index = await SourceIndexBuilder.build(
                from: ExtractedSource(source: StudySource(url: url), blocks: [.text(text)])
            )
            try await repository.store(index, state: .lexicalOnly)
            indexes.append(index)
        }
        return BenchmarkCorpus(indexes: indexes, repository: repository)
    }

    func lexicalRankings(_ questions: [Question]) async throws -> [[SourceChunk]] {
        var rankings: [[SourceChunk]] = []
        for question in questions {
            rankings.append(
                try await repository.lexicalSearch(
                    query: question.query,
                    fingerprints: indexes.map(\.fingerprint),
                    limit: 40
                )
            )
        }
        return rankings
    }

    func embeddedChunks() async throws -> [SourceVectorEntry] {
        let runner = LocalEmbeddingRunner.shared
        try await runner.prepare { _ in }
        let vectors = try await runner.embedDocuments(chunks.map(EmbeddingDocument.init(chunk:)))
        return zip(chunks, vectors).map { SourceVectorEntry(chunk: $0, vector: $1) }
    }

    func denseRankings(_ questions: [Question], entries: [SourceVectorEntry]) async throws -> [[SourceChunk]] {
        var rankings: [[SourceChunk]] = []
        for question in questions {
            let query = try await LocalEmbeddingRunner.shared.embedQuery(question.query)
            let scores = SourceRetriever.exactScores(query: query, entries: entries)
            rankings.append(
                zip(entries, scores)
                    .sorted { $0.1 > $1.1 }
                    .prefix(40)
                    .map(\.0.chunk)
            )
        }
        return rankings
    }

    func metrics(_ rankings: [[SourceChunk]], _ questions: [Question]) -> RetrievalEvaluationMetrics {
        RetrievalEvaluator.metrics(
            rankedChunkIDs: rankings.map { $0.map(\.id) },
            relevantChunkIDs: questions.map { question in
                Set(
                    chunks
                        .filter { $0.headingTitle?.hasSuffix(question.section) == true }
                        .map(\.id)
                )
            }
        )
    }

    static func report(_ label: String, _ metrics: RetrievalEvaluationMetrics) {
        let line = [
            "[benchmark] \(label.padding(toLength: 15, withPad: " ", startingAt: 0))",
            String(format: "hit@1 %.3f", metrics.hitAtOne),
            String(format: "recall@5 %.3f", metrics.recallAtFive),
            String(format: "MRR@10 %.3f", metrics.meanReciprocalRankAtTen)
        ].joined(separator: "  ")
        print(line)
    }

    struct Question {
        var query: String
        var section: String
    }

    static let tiers: [(String, [Question])] = [
        ("natural", questions),
        ("terse", terseQuestions)
    ]

    static let terseQuestions: [Question] = [
        Question(query: "powerhouse of the cell", section: "Mitochondria"),
        Question(query: "why aren't siblings genetically identical", section: "Meiosis"),
        Question(query: "how does insulin tell a cell to take up glucose", section: "Cell Signaling"),
        Question(query: "what keeps the cell's contents from leaking out", section: "Plasma Membrane"),
        Question(query: "chromatin", section: "Nucleus and DNA Storage"),
        Question(query: "tRNA anticodon", section: "Ribosomes and Protein Synthesis"),
        Question(query: "Robespierre's downfall", section: "The Thermidorian Reaction"),
        Question(query: "Varennes", section: "The Constitutional Monarchy"),
        Question(query: "women's rights in the revolution", section: "Declaration of the Rights of Man"),
        Question(query: "Napoleonic Code", section: "Legacy"),
        Question(query: "bread prices", section: "Causes of the Revolution"),
        Question(query: "why can't you build a perpetual motion machine", section: "The First Law"),
        Question(query: "coffee cooling down", section: "The Second Law and Entropy"),
        Question(query: "latent heat", section: "Phase Transitions"),
        Question(query: "Carnot", section: "Heat Engines"),
        Question(query: "heat pump efficiency", section: "Refrigerators and Heat Pumps"),
        Question(query: "Hess's law", section: "Enthalpy"),
        Question(query: "quantitative easing", section: "Monetary Policy"),
        Question(query: "10% reserve ratio", section: "The Money Multiplier"),
        Question(query: "why do the 1970s matter for the inflation and unemployment debate", section: "The Phillips Curve"),
        Question(query: "Solow", section: "Economic Growth"),
        Question(query: "real vs nominal", section: "Gross Domestic Product"),
        Question(query: "people between jobs", section: "Unemployment"),
        Question(query: "budget deficit in a downturn", section: "Fiscal Policy"),
        Question(query: "cheaper currency boosts exports", section: "Exchange Rates")
    ]

    static let questions: [Question] = [
        Question(query: "Who proposed that all living things are made of cells?", section: "Cell Theory"),
        Question(query: "Why can't charged ions cross the lipid bilayer on their own?", section: "Plasma Membrane"),
        Question(query: "How is the long DNA molecule packed so it fits inside the nucleus?", section: "Nucleus and DNA Storage"),
        Question(query: "Which organelle makes most of the cell's ATP?", section: "Mitochondria"),
        Question(query: "How is an mRNA message translated into a chain of amino acids?", section: "Ribosomes and Protein Synthesis"),
        Question(query: "Where are proteins modified and sorted before being shipped out of the cell?", section: "Endoplasmic Reticulum and Golgi"),
        Question(query: "What happens to the chromosomes during anaphase?", section: "Mitosis"),
        Question(query: "How does crossing over create genetic variation in gametes?", section: "Meiosis"),
        Question(query: "What is the difference between passive diffusion and active pumping?", section: "Membrane Transport"),
        Question(query: "How do hormones binding to receptors trigger a response inside the cell?", section: "Cell Signaling"),
        Question(query: "Why was the French monarchy nearly bankrupt before 1789?", section: "Causes of the Revolution"),
        Question(query: "Why did the Third Estate break away and swear the Tennis Court Oath?", section: "The Estates-General of 1789"),
        Question(query: "What happened when the crowd attacked the royal fortress in Paris on 14 July?", section: "Storming of the Bastille"),
        Question(query: "Which document declared that men are born free and equal in rights?", section: "Declaration of the Rights of Man"),
        Question(query: "How did the king's flight to Varennes undermine the 1791 constitution?", section: "The Constitutional Monarchy"),
        Question(query: "Why were so many people executed by guillotine under Robespierre?", section: "The Reign of Terror"),
        Question(query: "What happened after Robespierre fell from power?", section: "The Thermidorian Reaction"),
        Question(query: "Who governed France between 1795 and 1799?", section: "The Directory"),
        Question(query: "How did Bonaparte seize power in the coup of Brumaire?", section: "Rise of Napoleon"),
        Question(query: "What lasting influence did the revolution have on Europe?", section: "Legacy"),
        Question(query: "What is the difference between an open, closed, and isolated system?", section: "Systems and Surroundings"),
        Question(query: "Why does the law about thermal equilibrium allow us to build thermometers?", section: "The Zeroth Law"),
        Question(query: "How is internal energy related to the heat added and the work done?", section: "The First Law"),
        Question(query: "What does a negative delta H tell you about a reaction?", section: "Enthalpy"),
        Question(query: "Why does disorder in an isolated system always increase?", section: "The Second Law and Entropy"),
        Question(query: "What limits the efficiency of an engine running between a hot and a cold reservoir?", section: "Heat Engines"),
        Question(query: "How does a fridge move heat from a cold space to a warm room?", section: "Refrigerators and Heat Pumps"),
        Question(query: "How can I tell whether a reaction will happen spontaneously at constant temperature and pressure?", section: "Gibbs Free Energy"),
        Question(query: "What happens to entropy as temperature approaches absolute zero?", section: "The Third Law"),
        Question(query: "Why does the temperature stay constant while ice is melting?", section: "Phase Transitions"),
        Question(query: "How do economists measure the total output of a country?", section: "Gross Domestic Product"),
        Question(query: "What causes prices to rise across the whole economy?", section: "Inflation"),
        Question(query: "What are the frictional, structural and cyclical kinds of joblessness?", section: "Unemployment"),
        Question(query: "How can the government use taxes and spending to fight a recession?", section: "Fiscal Policy"),
        Question(query: "How does the central bank raising interest rates slow the economy?", section: "Monetary Policy"),
        Question(query: "How do banks create new money through lending?", section: "The Money Multiplier"),
        Question(query: "What shifts the AD curve and what happens to output and the price level?", section: "Aggregate Demand and Supply"),
        Question(query: "Is there a trade-off between inflation and unemployment?", section: "The Phillips Curve"),
        Question(query: "What happens to exports when a country's currency depreciates?", section: "Exchange Rates"),
        Question(query: "What makes an economy's productive capacity grow over the long run?", section: "Economic Growth")
    ]

    static let sources: [(String, String)] = [
        ("cell-biology.md", """
        # Cell Biology Notes

        ## 1. Cell Theory
        Cell theory states that every living organism is built from one or more cells, that the cell is the basic unit of structure and function, and that new cells arise only from pre-existing cells. Matthias Schleiden described plant tissues as cellular in 1838, Theodor Schwann extended the idea to animals in 1839, and Rudolf Virchow added omnis cellula e cellula in 1855. The theory replaced spontaneous generation and became the foundation of modern biology, linking anatomy, physiology and heredity to the behavior of individual cells.

        ## 2. Plasma Membrane
        The plasma membrane is a phospholipid bilayer studded with proteins and cholesterol. Hydrophilic phosphate heads face the watery inside and outside of the cell while hydrophobic fatty acid tails point inward. Small nonpolar molecules such as oxygen and carbon dioxide slip through easily, but ions and large polar molecules are blocked by the hydrophobic core and need channel or carrier proteins. The fluid mosaic model describes how lipids and proteins drift sideways within the layer, giving the membrane flexibility while keeping it selectively permeable.

        ## 3. Nucleus and DNA Storage
        The nucleus is enclosed by a double nuclear envelope perforated by nuclear pores that control traffic of RNA and proteins. Inside, each DNA molecule is wrapped around histone proteins to form nucleosomes, which coil further into chromatin fibers. This hierarchical packing compacts roughly two meters of DNA into a nucleus only a few micrometers wide. Loosely packed euchromatin is actively transcribed, whereas tightly packed heterochromatin is mostly silent. The nucleolus, a dense region within the nucleus, assembles ribosomal subunits.

        ## 4. Mitochondria
        Mitochondria are double-membrane organelles that carry out aerobic respiration. The inner membrane is folded into cristae, which hold the electron transport chain and ATP synthase. Pyruvate from glycolysis enters the matrix, where the Krebs cycle releases carbon dioxide and loads electron carriers. The electron transport chain pumps protons across the inner membrane, and the resulting gradient drives ATP synthase, producing most of the ATP a cell uses. Mitochondria contain their own circular DNA, supporting the endosymbiotic theory of their bacterial origin.

        ## 5. Ribosomes and Protein Synthesis
        Ribosomes are built from ribosomal RNA and protein and exist as free ribosomes in the cytoplasm or bound to the rough endoplasmic reticulum. During translation, the ribosome reads messenger RNA three bases at a time. Each codon pairs with the anticodon of a transfer RNA carrying a specific amino acid, and the ribosome links neighboring amino acids with peptide bonds. Translation starts at the AUG start codon and ends when a stop codon is reached, releasing the finished polypeptide, which then folds into its functional shape.

        ## 6. Endoplasmic Reticulum and Golgi
        The rough endoplasmic reticulum is covered with ribosomes and produces proteins destined for membranes or secretion, while the smooth endoplasmic reticulum makes lipids and detoxifies drugs. Proteins leave the ER in transport vesicles and travel to the Golgi apparatus, a stack of flattened cisternae. There they are modified by adding sugar chains, sorted, and packaged into new vesicles. Some vesicles fuse with the plasma membrane to release their contents by exocytosis, and others deliver enzymes to lysosomes.

        ## 7. Mitosis
        Mitosis divides one nucleus into two genetically identical nuclei. In prophase chromatin condenses into visible chromosomes and the spindle begins to form. In metaphase the chromosomes line up along the cell's equator, attached to spindle fibers at their kinetochores. During anaphase the sister chromatids separate and are pulled toward opposite poles as the spindle fibers shorten. In telophase new nuclear envelopes form around each set, and cytokinesis then splits the cytoplasm to produce two daughter cells.

        ## 8. Meiosis
        Meiosis produces four haploid gametes from one diploid cell through two rounds of division. In prophase I homologous chromosomes pair up and exchange segments in a process called crossing over, producing new combinations of alleles. Independent assortment in metaphase I shuffles maternal and paternal chromosomes randomly between the daughter cells. Meiosis II then separates sister chromatids much as in mitosis. Together, crossing over, independent assortment and random fertilization explain why offspring of the same parents differ genetically.

        ## 9. Membrane Transport
        Substances cross membranes by passive or active transport. Diffusion and facilitated diffusion move molecules down their concentration gradient and require no energy, while osmosis is the diffusion of water across a selectively permeable membrane. Active transport moves solutes against their gradient and consumes ATP; the sodium-potassium pump, for example, exports three sodium ions and imports two potassium ions per cycle. Large particles enter by endocytosis, in which the membrane folds inward to engulf them.

        ## 10. Cell Signaling
        Cells communicate with chemical signals such as hormones, neurotransmitters and growth factors. A signal molecule, or ligand, binds to a specific receptor either on the cell surface or inside the cell. Binding changes the receptor's shape and starts a signal transduction pathway, often involving second messengers like cyclic AMP and cascades of protein kinases that amplify the message. The pathway ends with a cellular response, such as switching on genes, opening ion channels or changing metabolism.
        """),
        ("french-revolution.md", """
        # The French Revolution

        ## 1. Causes of the Revolution
        By the late 1780s the French crown was deep in debt after costly wars, including support for the American War of Independence. The tax system was unfair: the clergy and nobility were largely exempt, so the burden fell on peasants and the middle class. Bad harvests in 1788 drove bread prices to record levels and caused widespread hunger. Enlightenment thinkers such as Rousseau and Montesquieu had spread ideas about popular sovereignty and the separation of powers, making many people question absolute monarchy.

        ## 2. The Estates-General of 1789
        Louis XVI summoned the Estates-General in May 1789 for the first time since 1614 to approve new taxes. Voting by order meant the clergy and nobility could always outvote the Third Estate, which represented the vast majority of the population. The Third Estate demanded voting by head, and when this was refused it declared itself the National Assembly. Locked out of its meeting hall, the Assembly gathered in a nearby indoor tennis court and swore not to disband until France had a constitution.

        ## 3. Storming of the Bastille
        On 14 July 1789 Parisian crowds, fearing that royal troops would dissolve the National Assembly, attacked the Bastille, a medieval fortress and prison that symbolized royal tyranny. They were looking for gunpowder and weapons. After several hours of fighting the governor surrendered, and he was killed by the crowd. The fall of the Bastille showed that the king had lost control of Paris, and it inspired peasant uprisings across the countryside known as the Great Fear.

        ## 4. Declaration of the Rights of Man
        In August 1789 the National Assembly abolished feudal privileges and adopted the Declaration of the Rights of Man and of the Citizen. It proclaimed that men are born and remain free and equal in rights, and that sovereignty rests with the nation rather than the king. It guaranteed liberty, property, security and resistance to oppression, freedom of speech and religion, and equality before the law. Critics such as Olympe de Gouges pointed out that it ignored the rights of women.

        ## 5. The Constitutional Monarchy
        The constitution of 1791 turned France into a constitutional monarchy in which the king shared power with an elected Legislative Assembly. Louis XVI never fully accepted the new order. In June 1791 the royal family tried to escape in disguise but was recognized and arrested at Varennes. The failed flight destroyed trust in the king and strengthened republicans. When war broke out with Austria and Prussia in 1792, suspicions of royal treason grew, and the monarchy was overthrown in August 1792.

        ## 6. The Reign of Terror
        In 1793 and 1794, facing foreign invasion and internal revolts, the Committee of Public Safety led by Maximilien Robespierre ruled through emergency measures. The Law of Suspects allowed arrest on vague charges of disloyalty, and revolutionary tribunals sent thousands to the guillotine, including Queen Marie Antoinette and many former revolutionaries. Robespierre argued that terror was necessary to protect the republic of virtue from its enemies. Roughly seventeen thousand people were officially executed, and many more died in prison or in the suppression of the Vendée revolt.

        ## 7. The Thermidorian Reaction
        On 9 Thermidor, or 27 July 1794, members of the National Convention who feared for their own lives turned on Robespierre. He was arrested and guillotined the next day along with his close allies. The period that followed, called the Thermidorian Reaction, dismantled the machinery of the Terror. The Jacobin Club was closed, political prisoners were released, and price controls were abandoned, which led to soaring inflation and hardship for the urban poor.

        ## 8. The Directory
        The constitution of 1795 created the Directory, an executive of five directors working with a two-chamber legislature. It was designed to prevent dictatorship but proved weak and corrupt. The government faced royalist plots on the right and radical conspiracies on the left, such as Babeuf's Conspiracy of Equals, and it repeatedly annulled elections it disliked. It increasingly relied on the army to stay in power, which raised the political influence of successful generals.

        ## 9. Rise of Napoleon
        Napoleon Bonaparte won fame through victories in Italy in 1796 and 1797 and a campaign in Egypt. In November 1799, in the coup of 18 Brumaire, he and his allies overthrew the Directory and established the Consulate with Napoleon as First Consul. A new constitution gave him almost all real power, and it was approved by a plebiscite. He made himself consul for life in 1802 and crowned himself Emperor of the French in 1804.

        ## 10. Legacy
        The revolution ended feudalism and absolute monarchy in France and spread the ideas of nationalism, popular sovereignty and equality before the law throughout Europe. The Napoleonic Code carried legal equality and secular administration into conquered territories. Its example inspired later revolutions in 1830 and 1848 and independence movements in Latin America. It also gave modern politics the language of left and right, taken from the seating of the National Assembly.
        """),
        ("thermodynamics.md", """
        # Thermodynamics

        ## 1. Systems and Surroundings
        In thermodynamics the system is the part of the universe under study and the surroundings are everything else. An open system exchanges both energy and matter with its surroundings, like a pot of boiling water without a lid. A closed system exchanges energy but not matter, like a sealed flask that can be heated. An isolated system exchanges neither energy nor matter; a well-insulated thermos is a close approximation. State functions such as pressure, volume and temperature describe the condition of a system.

        ## 2. The Zeroth Law
        The zeroth law states that if two bodies are each in thermal equilibrium with a third body, they are in thermal equilibrium with each other. This makes temperature a meaningful, measurable property. A thermometer works precisely because of this law: when it reaches equilibrium with an object, its reading tells us the temperature of that object, and any two objects with the same reading will not exchange heat when placed in contact.

        ## 3. The First Law
        The first law is the conservation of energy applied to thermodynamic systems. The change in internal energy of a system equals the heat added to the system minus the work done by the system, written as delta U equals Q minus W. Energy can be transferred as heat or work but cannot be created or destroyed. A perpetual motion machine that produces work without an energy input is therefore impossible.

        ## 4. Enthalpy
        Enthalpy, H, is defined as internal energy plus the product of pressure and volume. At constant pressure, the change in enthalpy equals the heat exchanged with the surroundings. Reactions with a negative change in enthalpy are exothermic and release heat, as in combustion. Reactions with a positive change are endothermic and absorb heat, as when ammonium nitrate dissolves in water. Hess's law lets us calculate enthalpy changes by adding the steps of a reaction pathway.

        ## 5. The Second Law and Entropy
        The second law states that the total entropy of an isolated system never decreases over time. Entropy measures the number of microscopic arrangements consistent with a system's macroscopic state, often described informally as disorder. Heat flows spontaneously from hot to cold bodies and not the reverse. Processes such as mixing gases or a cup of coffee cooling are irreversible because they increase total entropy, which gives time a direction.

        ## 6. Heat Engines
        A heat engine takes in heat from a hot reservoir, converts part of it to work and rejects the rest to a cold reservoir. Its efficiency is the work output divided by the heat input. The Carnot efficiency, one minus the ratio of cold to hot reservoir temperatures in kelvin, is the maximum any engine can reach between two temperatures. Real engines such as car engines and steam turbines fall well below this limit because of friction and other irreversible losses.

        ## 7. Refrigerators and Heat Pumps
        A refrigerator is a heat engine run in reverse. It uses work, supplied by a compressor, to move heat from a cold interior to the warmer kitchen. A refrigerant evaporates inside the cold coils, absorbing heat, and is then compressed and condensed in the outside coils, releasing heat. Performance is measured by the coefficient of performance, the heat moved divided by the work input. A heat pump uses the same cycle to warm a building by pulling heat from the outdoor air.

        ## 8. Gibbs Free Energy
        Gibbs free energy combines enthalpy and entropy as G equals H minus T times S. At constant temperature and pressure, a process is spontaneous when the change in Gibbs free energy is negative, at equilibrium when it is zero, and non-spontaneous when it is positive. A reaction that absorbs heat can still be spontaneous if its entropy increase is large enough at high temperature. The standard free energy change is also related to the equilibrium constant of a reaction.

        ## 9. The Third Law
        The third law states that the entropy of a perfect crystal approaches zero as its temperature approaches absolute zero. This provides a reference point for calculating absolute entropies of substances. A consequence is that absolute zero cannot be reached in a finite number of steps, because each cooling step removes a smaller and smaller amount of entropy.

        ## 10. Phase Transitions
        A phase transition is a change between solid, liquid and gas. During melting or boiling, energy added to the substance breaks intermolecular attractions instead of raising the kinetic energy of the particles, so the temperature stays constant until the change is complete. The energy required is called latent heat: the latent heat of fusion for melting and the latent heat of vaporization for boiling. A phase diagram shows which phase is stable at each pressure and temperature and marks the triple point and critical point.
        """),
        ("macroeconomics.md", """
        # Macroeconomics

        ## 1. Gross Domestic Product
        Gross domestic product is the market value of all final goods and services produced within a country in a given period. It can be measured by the expenditure approach, adding consumption, investment, government purchases and net exports, by the income approach, adding wages, rents, interest and profits, or by the production approach, adding the value added at each stage. Nominal GDP uses current prices, while real GDP adjusts for inflation so that output can be compared across years.

        ## 2. Inflation
        Inflation is a sustained rise in the general price level, usually measured by the consumer price index. Demand-pull inflation occurs when total spending grows faster than the economy's capacity to produce. Cost-push inflation occurs when production costs such as wages or oil prices rise and firms pass them on. Rapid growth of the money supply is a common long-run cause. Inflation erodes purchasing power, redistributes wealth from lenders to borrowers when unexpected, and creates uncertainty for planning.

        ## 3. Unemployment
        A person is unemployed if they are without a job, available for work and actively looking. Frictional unemployment comes from people moving between jobs or entering the labor force. Structural unemployment arises when workers' skills or locations do not match available jobs, for example after automation. Cyclical unemployment rises during recessions when demand falls. The natural rate of unemployment includes frictional and structural unemployment but not cyclical unemployment.

        ## 4. Fiscal Policy
        Fiscal policy is the government's use of taxation and spending to influence the economy. During a recession, expansionary fiscal policy cuts taxes or increases government spending to raise aggregate demand and employment, often financed by a budget deficit. During a boom, contractionary policy raises taxes or cuts spending to cool demand. The multiplier effect means that an increase in spending raises total output by more than the initial amount, though crowding out of private investment can weaken the effect.

        ## 5. Monetary Policy
        Monetary policy is conducted by the central bank, which sets short-term interest rates and controls the money supply. When the central bank raises its policy rate, borrowing becomes more expensive for households and firms, so consumption and investment fall, the currency tends to appreciate, and inflation slows. Cutting rates has the opposite effect. Tools include open market operations, the discount rate, reserve requirements and, when rates are near zero, quantitative easing.

        ## 6. The Money Multiplier
        Commercial banks keep only a fraction of their deposits as reserves and lend out the rest. When a loan is spent, it is deposited in another bank, which in turn lends out part of it. Through this repeated lending, an initial deposit creates a much larger total amount of money. The simple money multiplier equals one divided by the reserve ratio, so a ten percent reserve requirement gives a multiplier of ten. In practice the effect is smaller because people hold cash and banks keep excess reserves.

        ## 7. Aggregate Demand and Supply
        Aggregate demand is the total spending on an economy's output at each price level, and the AD curve slopes downward. Aggregate supply shows how much firms produce at each price level. An increase in consumer confidence, government spending or exports shifts the AD curve to the right, raising both real output and the price level in the short run. A supply shock such as a sharp rise in oil prices shifts short-run aggregate supply to the left, causing stagflation: lower output and higher prices.

        ## 8. The Phillips Curve
        The Phillips curve describes an inverse relationship between inflation and unemployment observed in historical data: lower unemployment tended to come with higher inflation. In the short run, policymakers may face this trade-off. Milton Friedman and Edmund Phelps argued that in the long run the curve is vertical at the natural rate of unemployment, because workers adjust their inflation expectations. The stagflation of the 1970s, with high inflation and high unemployment together, supported their view.

        ## 9. Exchange Rates
        An exchange rate is the price of one currency in terms of another. Under a floating regime it is set by supply and demand in foreign exchange markets, while under a fixed regime the central bank defends a target. When a currency depreciates, a country's exports become cheaper for foreign buyers and imports become more expensive, which tends to improve the trade balance over time. Higher domestic interest rates attract foreign capital and usually cause the currency to appreciate.

        ## 10. Economic Growth
        Long-run economic growth is a sustained increase in real GDP per person. It depends on growth in physical capital, human capital through education and training, and above all technological progress, which raises productivity. The Solow model shows that capital accumulation alone runs into diminishing returns, so sustained growth requires technology. Institutions such as secure property rights, the rule of law and stable government encourage the investment and innovation that drive growth.
        """)
    ]
}
